#include "nvidia_transcoder.h"

#include <chrono>
#include <cstring>
#include <iostream>
#include <utility>
#include <spdlog/spdlog.h>

#include "execution_profiler.h"
#include "multiscaling_pipeline.h"
#include "nvidia/nvidia_decoding_pipeline.h"
#include "nvidia/nvidia_encoding_pipeline.h"
#include "nvidia/nvidia_multiscaling_pipeline.h"
#include "nvidia/nvidia_timestamp_emitter.h"

// FFmpeg related imports
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/fifo.h>
#include <libavutil/opt.h>
}

#define MAX_OUTPUTS 4

void handle_destroy_state(UnifexEnv* env, UnifexState* state) {
  UNIFEX_UNUSED(env);

  auto& execution_profiler = state->transcoding_pipeline->GetExecutionProfiler();

  for (auto [label, summary] : execution_profiler.Summaries()) {
    spdlog::debug(
      "Profiler summary for {}: max_time = {}μs, min_time = {}μs, avg_time = {}μs, total_time = {}μs, measurements = {}",
      label,
      summary.max_time,
      summary.min_time,
      summary.average_time,
      summary.total_time,
      summary.measurements
    );
  }

  state->~State();
}

#include <vector>

UNIFEX_TERM create(UnifexEnv* env,
                   abr_stream_params original_stream_params,
                   abr_stream_params* target_streams,
                   unsigned int target_streams_length) {
  if (target_streams_length > MAX_OUTPUTS || target_streams_length < 1) {
    return create_result_error(env, "invalid number of outputs");
  }

  UNIFEX_TERM result;

  State* state = unifex_alloc_state(env);
  state = new (state) State();

  spdlog::set_level(spdlog::level::info);

  try {
    auto device_context = std::make_shared<NvidiaDeviceContext>(target_streams_length);

    spdlog::debug("Initializing nvidia device context...");
    if (!device_context->Initialize()) {
      throw std::runtime_error("Failed to initialize nvidia device context");
    }
    spdlog::debug("Nvidia device context initialized");

    spdlog::debug("Initializing decoder...");
    std::unique_ptr<DecodingPipeline<AVFrame>> decoding_pipeline =
        std::make_unique<NvidiaDecodingPipeline>(
            original_stream_params.width,
            original_stream_params.height,
            original_stream_params.framerate,
            original_stream_params.bitrate,
            device_context);
    spdlog::debug("Initialized decoder");

    MultiScalerInput multiscaler_input = {original_stream_params.width,
                                          original_stream_params.height,
                                          original_stream_params.framerate};
    std::vector<MultiScalerOutput> multiscaler_outputs;

    for (unsigned int i = 0; i < target_streams_length; i++) {
      multiscaler_outputs.push_back({i,
                                     target_streams[i].width,
                                     target_streams[i].height,
                                     target_streams[i].framerate});
    }

    spdlog::debug("Initializing multiscaler");
    std::unique_ptr<MultiscalingPipeline<AVFrame>> multiscaling_pipeline =
        std::make_unique<NvidiaMultiscalingPipeline>(
            multiscaler_input, multiscaler_outputs, device_context);
    spdlog::debug("Multiscaler initialized");

    spdlog::debug("Initializing encoders...");
    std::vector<std::unique_ptr<EncodingPipeline<AVFrame>>> encoding_pipelines;
    for (unsigned int i = 0; i < target_streams_length; i++) {

      auto nvidia_multiscaling_pipeline =
          dynamic_cast<NvidiaMultiscalingPipeline*>(
              multiscaling_pipeline.get());
      auto timestamp_emitter = NvidiaTimestampEmitter(
          nvidia_multiscaling_pipeline->RequiresTimestampHalving(i),
          nvidia_multiscaling_pipeline->RequiresOffsetHalving(i));

      std::unique_ptr<EncodingPipeline<AVFrame>> encoding_pipeline =
          std::make_unique<NvidiaEncodingPipeline>(i,
                                                   target_streams[i].width,
                                                   target_streams[i].height,
                                                   target_streams[i].framerate,
                                                   target_streams[i].bitrate,
                                                   timestamp_emitter,
                                                   device_context);

      encoding_pipelines.push_back(std::move(encoding_pipeline));
    }

    spdlog::debug("Encoders initialized");

    state->transcoding_pipeline =
        std::make_unique<TranscodingPipeline<AVFrame, stream_frame>>(
            std::move(decoding_pipeline),
            std::move(multiscaling_pipeline),
            std::move(encoding_pipelines));

    /*
    ⣿⣿⣿⣿⣿⣿⣿⣿⡿⠋⠁⠀⠉⠙⠛⠿⠛⠉⠀⠀⠀⠉⢻⣿⣿⣿⣿⣿⣿⣿
    ⣿⣿⣿⣿⣿⣿⡿⠋⠀⢀⠔⠒⠒⠒⠒⠀⠠⠔⠚⠉⠉⠁⠀⠙⢿⣿⣿⣿⣿⣿
    ⣿⣿⣿⣿⠟⢋⠀⠀⠀⠀⣠⢔⠤⠀⢤⣤⡀⠠⣢⡭⠋⡙⢿⣭⡨⠻⣿⣿⣿⣿
    ⣿⣿⣿⠇⢀⠆⠀⠀⠀⣪⣴⣿⠐⢬⠀⣿⡗⣾⣿⡇⠈⠦⢸⣿⠗⢠⠿⠿⣿⣿
    ⣿⣿⡏⠀⠀⠀⢀⡀⠀⠈⠛⠻⠄⠀⠠⠋⠀⠈⠛⠻⠆⠀⠈⢀⡠⣬⣠⢣⣶⢸
    ⣿⡿⠀⠀⠀⣶⡌⣇⣿⢰⠷⠦⠄⣀⣀⣀⣀⣀⣀⣠⣤⠶⠞⡛⠁⣿⣿⣾⣱⢸
    ⣿⡇⠀⠀⠀⣬⣽⣿⣿⢸⡜⢿⣷⣶⣶⣶⣯⣽⣦⡲⣾⣿⡇⣿⠀⣌⠿⣿⠏⣼
    ⣿⡇⠀⠀⠀⠹⣿⡿⢫⡈⠻⢦⡹⢟⣛⣛⣛⣛⣛⣡⠿⣫⡼⠃⠀⣿⡷⢠⣾⣿
    ⣿⡇⡀⠀⠀⠀⠀⠰⣿⣷⡀⠀⠙⠳⠦⣭⣭⣭⣵⡶⠿⠋⠀⢀⣴⣿⡇⣾⣿⣿
    ⣿⢠⣿⣦⣄⣀⠀⠀⢻⣿⣧⠀⠀⠀⠀⠀⠀⠀⠀⠀ ⣀⣤⣶⣿⣿⡟⣰⣿⣿
    ⡇⣸⣿⣿⣿⣿⣿⣷⣦⢹⣿⣇⢠⣤⣤⣤⣤⣶⣾⣿⣿⣿⣿⣿⣿⡇⢹⣿⣿⣿
    ⡇⣿⣿⣿⣿⣿⣿⣿⣿⣎⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠏⣸⣿⣿⣿
    ⣧⡘⠿⢿⣿⣿⣿⣿⣿⣿⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠟⢋⣡⣾⣿⣿⣿⣿
    ⣿⣿⣿⣶⣤⣍⣉⣛⣛⡛⠛⠛⢛⣛⣛⣛⣛⣉⣩⣭⣤⣴⣶⣿⣿⣿⣿⣿⣿⣿
    */

    spdlog::debug("Initialized transcoding pipeline");
    result = create_result_ok(env, state);

  } catch (std::exception& e) {
    result = create_result_error(env, e.what());
  }

  unifex_release_state(env, state);

  return result;
}

stream_frame encoded_frame_to_stream_frame(UnifexEnv* env,
                                           uint32_t output_id,
                                           EncodedFrame encoded_frame) {
  UnifexPayload* new_payload =
      (UnifexPayload*)unifex_alloc(sizeof(UnifexPayload));
  unifex_payload_alloc(
      env, UNIFEX_PAYLOAD_BINARY, encoded_frame.size, new_payload);
  memcpy(new_payload->data, encoded_frame.data, encoded_frame.size);

  stream_frame frame;
  frame.id = output_id;
  frame.payload = new_payload;
  frame.pts = encoded_frame.pts;
  frame.dts = encoded_frame.dts;

  return frame;
}

/*
 * Processes a H264 frame and produces a number of output frames
 * that are accordingly scaled and encoded.
 *
 * To make sure that the transcoded output frames are aligned keyframe and
 * timestamp wise the function takes into consideration the number of frames
 * that were dropped between input frames.
 *
 * @param env Unifex environment.
 * @param payload Unifex payload containing the H264 frame.
 * @param frames_gap Number of frames that were dropped just before this frame.
 * @param state Unifex state.
 * @return Unifex term that encodes the processed result.
 */
UNIFEX_TERM process(UnifexEnv* env,
                    UnifexPayload* payload,
                    int frames_gap,
                    UnifexState* state) {
  UNIFEX_TERM result;

  unsigned char* data = payload->data;
  int data_size = payload->size;

  std::vector<stream_frame> stream_frames;

  if (frames_gap > 0) {
    state->transcoding_pipeline->OnFrameGap((uint32_t)frames_gap);
  }

  try {
    stream_frames = state->transcoding_pipeline->Process(
        data,
        data_size,
        [&env](uint32_t output_id, EncodedFrame encoded_frame) -> stream_frame {
          return encoded_frame_to_stream_frame(env, output_id, encoded_frame);
        });

    result = process_result_ok(env, stream_frames.data(), stream_frames.size());
  } catch (const std::exception& e) {
    result = process_result_error(env, e.what());
  }

  for (size_t i = 0; i < stream_frames.size(); i++) {
    unifex_payload_release(stream_frames[i].payload);
    unifex_free(stream_frames[i].payload);
  }

  return result;
}

UNIFEX_TERM update_sps_and_pps(UnifexEnv* env,
                               UnifexPayload* sps_and_pps,
                               UnifexState* state) {
  state->transcoding_pipeline->OnStreamParameters(sps_and_pps->data,
                                                  sps_and_pps->size);

  return update_sps_and_pps_result_ok(env);
}

/*
 * Flushes every encoder and potentially reduces leftover frames.
 */
UNIFEX_TERM
flush(UnifexEnv* env, UnifexState* state) {
  UNIFEX_TERM result;

  std::vector<stream_frame> stream_frames;

  try {
    stream_frames = state->transcoding_pipeline->Flush(
        [&env](int stream_id, EncodedFrame encoded_frame) -> stream_frame {
          return encoded_frame_to_stream_frame(env, stream_id, encoded_frame);
        });

    result = flush_result_ok(env, stream_frames.data(), stream_frames.size());
  } catch (const std::exception& e) {
    result = flush_result_error(env, e.what());
  }

  for (size_t i = 0; i < stream_frames.size(); i++) {
    unifex_payload_release(stream_frames[i].payload);
    unifex_free(stream_frames[i].payload);
  }

  return result;
}
