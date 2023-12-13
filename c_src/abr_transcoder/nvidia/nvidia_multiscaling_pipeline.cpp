#include "nvidia_multiscaling_pipeline.h"

#include <algorithm>
#include <sstream>
#include <vector>
#include <stdexcept>
#include <string_view>
#include <spdlog/spdlog.h>

std::string createGraphFilterSpec(MultiScalerInput input,
                                  const std::vector<MultiScalerOutput>& outputs) {
  std::stringstream ss;

  ss << "[in]hwupload_cuda,split=" << outputs.size() ;
  for (size_t i = 0; i < outputs.size(); i++) {
    ss << "[in_" << i << "]";
  }
  ss << "; ";

  for (size_t i = 0; i < outputs.size(); i++) {
    auto down_rate =
        outputs[i].framerate < input.framerate;
    ss << "[in_" << i << "]";
    if (down_rate) {
      ss << "fps=" << outputs[i].framerate << ",";
    }

    ss << "scale_npp=" << outputs[i].width << ":" << outputs[i].height << "[out_" << i << "]; ";
  }

  return ss.str();
}

NvidiaMultiscalingPipeline::NvidiaMultiscalingPipeline(
    MultiScalerInput input,
    std::vector<MultiScalerOutput> outputs,
    std::shared_ptr<NvidiaDeviceContext> device_context
    )
    : MultiscalingPipeline(input, outputs) {
  const AVFilter* buffersrc = avfilter_get_by_name("buffer");
  const AVFilter* buffersink = avfilter_get_by_name("buffersink");

  if (!buffersrc) {
    throw std::runtime_error("Failed to find buffersrc filter");
  }
  if (!buffersink) {
    throw std::runtime_error("Failed to find buffersink filter");
  }

  auto graph_filter_spec = createGraphFilterSpec(input, outputs);

  buffer_sinks.resize(outputs.size());
  scaled_frame_counts.resize(outputs.size());
  keyframe_positions.resize(outputs.size());
  frame_gap_positions.resize(outputs.size());
  skip_frame_positions.resize(outputs.size());
  output_half_rate_filter_applied.resize(outputs.size());

  // Create the graph filter consisting of the multiscaler
  graph = avfilter_graph_alloc();
  graph->nb_threads = 4;

  std::stringstream ss;
  ss << "video_size=" << input.width << "x" << input.height
     << ":pix_fmt=" << AV_PIX_FMT_NV12 << ":time_base=" << 1 << "/"
     << input.framerate << ":pixel_aspect=1/1";

  auto args = ss.str();

  int ret = 0;
  if ((ret = avfilter_graph_create_filter(
           &buffer_source, buffersrc, "in", args.c_str(), nullptr, graph)) < 0) {
    avfilter_graph_free(&graph);
    throw std::runtime_error("Cannot create buffer sink");
  }

  AVFilterInOut* filter_inputs = avfilter_inout_alloc();
  AVFilterInOut* inputs = filter_inputs;
  inputs->next = NULL;
  // Connect the graph filter with buffer sinks
  for (int i = 0; i < (int)outputs.size(); i++) {
    char link_name[64];
    snprintf(link_name, sizeof(link_name), "out_%d", i);

    if ((ret = avfilter_graph_create_filter(
             &buffer_sinks[i], buffersink, link_name, nullptr, nullptr, graph)) < 0) {
      avfilter_inout_free(&filter_inputs);
      avfilter_graph_free(&graph);
      throw std::runtime_error("Cannot create buffer sink");
    }

    enum AVPixelFormat pix_fmts[] = {AV_PIX_FMT_CUDA, AV_PIX_FMT_NONE};

    ret = av_opt_set_int_list(buffer_sinks[i], "pix_fmts", pix_fmts, AV_PIX_FMT_NONE, AV_OPT_SEARCH_CHILDREN);
    if (ret < 0) {
      avfilter_inout_free(&filter_inputs);
      avfilter_graph_free(&graph);
      throw  std::runtime_error("Couldn't set output pixel format for rescaling");
    }


    // if the current input has a name we need to create another node
    if (inputs->name != NULL) {
      AVFilterInOut* tmp = avfilter_inout_alloc();
      tmp->next = inputs;
      inputs = tmp;
    }

    inputs->name = av_strdup(link_name);
    inputs->filter_ctx = buffer_sinks[i];
    inputs->pad_idx = 0;
    filter_inputs = inputs;
  }


  AVFilterInOut* filter_outputs = avfilter_inout_alloc();
  filter_outputs->name = av_strdup("in");
  filter_outputs->filter_ctx = buffer_source;
  filter_outputs->pad_idx = 0;
  filter_outputs->next = NULL;


  spdlog::debug("Parsing filter graph: {}", graph_filter_spec.c_str());
  ret = avfilter_graph_parse_ptr(
      graph, graph_filter_spec.c_str(), &filter_inputs, &filter_outputs, device_context->GetDeviceContext(), nullptr);
  if (ret < 0) {
    // avfilter_graph_parse_ptr in case of an error will free both filter_inputs and filter_outputs
    avfilter_graph_free(&graph);
    throw std::runtime_error("Invalid filter graph definition");
  }

  spdlog::debug("Configuring filter graph");
  if ((ret = avfilter_graph_config(graph, NULL)) < 0) {
    avfilter_graph_free(&graph);
    throw std::runtime_error("Failed to configure graph");
  }
  spdlog::debug("Filter graph configured");

  for (const auto& output : outputs) {
    output_half_rate_filter_applied[output.id] =
        output.framerate < input.framerate;
  }

  for (unsigned int i = 0; i < buffer_sinks.size(); i++) {
    device_context->PutFrameContext(i, av_buffersink_get_hw_frames_ctx(buffer_sinks[i]));
  }

  auto any_output_halved =
      std::any_of(output_half_rate_filter_applied.begin(),
                  output_half_rate_filter_applied.end(),
                  [](const auto& halved) { return halved; });

  any_half_rate_filter_applied = any_output_halved;

  // allocate at the end to avoid freeing on any error
  scaled_frame = av_frame_alloc();
}

NvidiaMultiscalingPipeline::~NvidiaMultiscalingPipeline() {
  // filter inputs/outputs and buffer_source are freed by freeing the graph
  avfilter_graph_free(&graph);
  av_frame_free(&scaled_frame);
}

bool NvidiaMultiscalingPipeline::RequiresTimestampHalving(
    ScalerOutputID output_id) const {
      (void)output_id;
      return false;
}

bool NvidiaMultiscalingPipeline::RequiresOffsetHalving(
    ScalerOutputID output_id) const {
  (void)output_id;

  return output_half_rate_filter_applied[output_id];
}

void NvidiaMultiscalingPipeline::EnqueueKeyFrame(
    const VideoFrame<AVFrame>& video_frame) {
  if (video_frame.is_keyframe) {
    for (const auto& output : outputs) {
      uint32_t keyframe_at = video_frame.id + repeated_input_frames;

      if (output_half_rate_filter_applied[output.id]) {
        keyframe_at = (keyframe_at + 1) / 2;
      }

      auto& queue = keyframe_positions[output.id];

      if (queue.empty()) {
        queue.push(keyframe_at);
      } else if (queue.front() == keyframe_at && output_half_rate_filter_applied[output.id]) {
        // In case of half-rate outputs it may happen that we get 2 consecutive keyframes queued (frame dropping).
        // When it happens just ignore the recent keyframe request.
        continue;
      } else if (queue.front() == keyframe_at) {
        throw std::runtime_error("Keyframe request already queued.");
      } else if (queue.front() > keyframe_at) {
        throw std::runtime_error("Keyframe request is in the past.");
      } else {
        queue.push(keyframe_at);
      }
    }
  }
}

bool NvidiaMultiscalingPipeline::DequeueKeyFrame(ScalerOutputID output_id,
                                                 uint32_t frame_num) {
  auto& queue = keyframe_positions[output_id];

  if (queue.empty() || queue.front() > frame_num) {
    return false;
  }

  if (queue.front() == frame_num) {
    queue.pop();
    return true;
  }

  if (queue.front() < frame_num) {
    throw std::runtime_error("Missed a keyframe generation request");
  }

  return false;
}

void NvidiaMultiscalingPipeline::EnqueueFrameGap(
    const VideoFrame<AVFrame>& frame) {
  if (frame.frames_gap <= 0) {
    return;
  }

  uint32_t current_frame_number = frame.id + repeated_input_frames;

  // When dealing with filters that are responsible for dropping frames
  // they usually drop every other frame (at odd position, starting from 0).
  //
  // This is fine when the source stream doesn't contain any
  // frame drops. Once the stream contains frame drops, the filter may drop a frame that contains
  // a really big gap, and given a following frame that can also contain a big gap, their sum
  // would appear as one gap in the halved framerate streams.
  //
  // Example: source frame is preceeded by 120 frames gap, the following frames again is preceeded by 120 gap.
  // Because in the half-rate stream the first frame will be dropped, the resulting gap will be 240 frames which
  // will cause a too big gap when creating chunked media stream (a single frame will be larger than the allowed segment duraiton).
  //
  // To avoid this, we repeat the current frame (in the source stream), so the frame will appear in the half-rate stream
  // (the repeated frame will be skipped first, just like the FPS filter does,
  // and for the second time it will be regurarly produced). Because we are repeating the frame we need to
  // account for this when working with full-rate streams (adjust the timestamps and skip the frame encoding).
  bool repeat_current_input_frame = false;
  if (any_half_rate_filter_applied && current_frame_number % 2) {
    repeat_current_input_frame = true;
    repeated_input_frames++;
    current_frame_number++;
    last_input_frame = std::optional{frame};
  }

  for (const auto& output : outputs) {
    int frame_gap_at;
    uint32_t gap = frame.frames_gap;

    if (output_half_rate_filter_applied[output.id]) {
      frame_gap_at = current_frame_number / 2;
    } else {
      frame_gap_at = current_frame_number;
    }

    // When we are repeating the frame we are in fact producing 2 frames, one of
    // which will get skipped. The second frame though will have its PTS value incremented
    // so we need to compensate for that by decreasing the gap by 1.
    //
    // This gap decrement also applies to the case when the input framerate is halved. In this case,
    // the half-rate streams sees the repeated frame as a regular frame therefore we need to decrement the gap.
    if (repeat_current_input_frame) {
      gap--;
    }

    if (gap > 0) {
      frame_gap_positions[output.id].push(std::make_pair(frame_gap_at, gap));
    }

    // We are only skippping a frame when the output framerate is the same
    // as the input framerate and when there exists any framerate halving.
    //
    // Because we are incrementing the `current_frame_number` by one, the repeated frame
    // will occur at `current_frame_number` - 1 position and that is the frame that we need
    // to mark for skipping.
    if (!output_half_rate_filter_applied[output.id] && repeat_current_input_frame) {
      EnqueueFrameSkip(output.id, current_frame_number - 1);
    }
  }
}

uint32_t NvidiaMultiscalingPipeline::DequeueFrameGap(ScalerOutputID output_id,
                                                     uint32_t frame_num) {
  auto& queue = frame_gap_positions[output_id];

  if (queue.empty()) {
    return 0;
  }

  auto [gap_frame_num, gap] = queue.front();

  if (gap_frame_num > frame_num) {
    return 0;
  }

  if (gap_frame_num < frame_num) {
    throw std::runtime_error("Missed a frame gap assignment");
  }

  queue.pop();

  return gap;
}

void NvidiaMultiscalingPipeline::EnqueueFrameSkip(ScalerOutputID output_id,
                                                  uint32_t frame_num) {
  skip_frame_positions[output_id].push(frame_num);
}

bool NvidiaMultiscalingPipeline::DequeueFrameSkip(ScalerOutputID output_id,
                                                  uint32_t frame_num) {
  if (skip_frame_positions[output_id].empty()) {
    return false;
  }

  if (skip_frame_positions[output_id].front() < frame_num) {
    throw std::runtime_error("Missed a frame skip assignment");
  }

  if (skip_frame_positions[output_id].front() == frame_num) {
    skip_frame_positions[output_id].pop();
    return true;
  }

  return false;
}

void NvidiaMultiscalingPipeline::Process(VideoFrame<AVFrame>& video_frame) {
  std::vector<std::pair<ScalerOutputID, VideoFrame<AVFrame>>> frames;
  EnqueueFrameGap(video_frame);
  EnqueueKeyFrame(video_frame);

  video_frame.frame->pts = last_pts++;
  int ret = av_buffersrc_add_frame_flags(
      buffer_source, video_frame.frame, AV_BUFFERSRC_FLAG_KEEP_REF);

  if (ret < 0) {
    throw std::runtime_error("Failed to push the frame to filter graph");
  }

  if (last_input_frame) {
    last_input_frame->frame->pts = last_pts++;
    ret = av_buffersrc_add_frame_flags(
        buffer_source, last_input_frame->frame, AV_BUFFERSRC_FLAG_KEEP_REF);
    if (ret < 0) {
      throw std::runtime_error(
          "Failed to send again the frame to filter graph");
    }

    last_input_frame = std::nullopt;
  }
}

// multiscaler does not have any internal buffers so we don't need to flush it
void NvidiaMultiscalingPipeline::Flush() { return; }

std::optional<std::pair<ScalerOutputID, VideoFrame<AVFrame>>>
NvidiaMultiscalingPipeline::GetNext() {
  while (true) {
    if (currently_read_output >= outputs.size()) {
      currently_read_output = 0;
      return std::nullopt;
    }

    av_frame_unref(scaled_frame);

    int sink_ret = av_buffersink_get_frame(buffer_sinks[currently_read_output],
                                           scaled_frame);
    if (sink_ret == AVERROR(EAGAIN) || sink_ret == AVERROR_EOF) {
      currently_read_output++;
      continue;
    } else if (sink_ret < 0) {
      throw std::runtime_error("Failed to read scaled frame");
    }

    uint32_t scaled_frame_id = scaled_frame_counts[currently_read_output]++;

    bool is_keyframe = DequeueKeyFrame(currently_read_output, scaled_frame_id);
    if (is_keyframe) {
      scaled_frame->pict_type = AV_PICTURE_TYPE_I;
    }

    bool skip_processing =
        DequeueFrameSkip(currently_read_output, scaled_frame_id);

    uint32_t frame_gap =
        DequeueFrameGap(currently_read_output, scaled_frame_id);

    auto frame = VideoFrame{
        scaled_frame_id, scaled_frame, is_keyframe, frame_gap, skip_processing};
    return std::optional{std::make_pair(currently_read_output, frame)};
  }
}
