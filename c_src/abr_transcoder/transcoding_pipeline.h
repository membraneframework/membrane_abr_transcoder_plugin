

#include "decoding_pipeline.h"
#include "encoding_pipeline.h"
#include "multiscaling_pipeline.h"
#include "execution_profiler.h"
#include <functional>
#include <memory>

template <typename FrameType, typename Output> class TranscodingPipeline {
public:
  using OutputID = uint32_t;
  using EncodedFrameTransformer = std::function<Output(OutputID, EncodedFrame)>;

  TranscodingPipeline(
      std::unique_ptr<DecodingPipeline<FrameType>> decoding_pipeline,
      std::unique_ptr<MultiscalingPipeline<FrameType>> multiscaling_pipeline,
      std::vector<std::unique_ptr<EncodingPipeline<FrameType>>>
          encoding_pipelines)
      : decoding_pipeline(std::move(decoding_pipeline)),
        multiscaling_pipeline(std::move(multiscaling_pipeline)),
        encoding_pipelines(std::move(encoding_pipelines)),
        profiler({"total", "decode", "scale", "encode"}),
        flushed(false) {}

  void OnFrameGap(uint32_t frame_gap) {
    decoding_pipeline->OnFrameGap(frame_gap);
  }

  void OnStreamParameters(const uint8_t* payload, size_t size) {
    decoding_pipeline->OnStreamParameters(payload, size);
  }

  std::vector<Output> Process(const uint8_t* payload,
                              size_t size,
                              EncodedFrameTransformer frame_transformer) {
    std::vector<Output> output_frames;

    profiler.StartTimer("total");
    profiler.StartTimer("decode");
    decoding_pipeline->Process(payload, size);
    while (auto decoded_video_frame = decoding_pipeline->GetNext()) {
      profiler.StopTimer("decode");

      profiler.StartTimer("scale");
      multiscaling_pipeline->Process(*decoded_video_frame);

      while (auto scaling_output = multiscaling_pipeline->GetNext()) {
        profiler.StopTimer("scale");

        auto [stream_id, scaled_video_frame] = *scaling_output;

        profiler.StartTimer("encode");
        auto& encoding_pipeline = encoding_pipelines[stream_id];
        encoding_pipeline->Process(scaled_video_frame);
        while (auto encoded_frame = encoding_pipeline->GetNext()) {
          output_frames.push_back(frame_transformer(stream_id, *encoded_frame));
          encoded_frame = encoding_pipelines[stream_id]->GetNext();
        }
        profiler.StopTimer("encode");
      }
    }
    profiler.StopTimer("total");

    return output_frames;
  }

  std::vector<Output> Flush(EncodedFrameTransformer frame_transformer) {
    std::vector<Output> output_frames;

    if (flushed) return output_frames;
    flushed = true;

    profiler.StartTimer("decode");
    decoding_pipeline->Flush();
    while (auto decoded_video_frame = decoding_pipeline->GetNext()) {
      profiler.StartTimer("decode");
      profiler.StartTimer("scale");
      multiscaling_pipeline->Process(*decoded_video_frame);

      while (auto scaling_output = multiscaling_pipeline->GetNext()) {
        profiler.StopTimer("scale");
        auto [stream_id, scaled_video_frame] = *scaling_output;

        profiler.StartTimer("encode");
        auto& encoding_pipeline = encoding_pipelines[stream_id];
        encoding_pipeline->Process(scaled_video_frame);
        while (auto encoded_frame = encoding_pipeline->GetNext()) {
          profiler.StopTimer("encode");
          output_frames.push_back(frame_transformer(stream_id, *encoded_frame));
        }
      }
    }

    for (auto& encoding_pipeline : encoding_pipelines) {
      auto stream_id = encoding_pipeline->GetOutputID();
      profiler.StartTimer("encode");
      encoding_pipeline->Flush();

      while (auto encoded_frame = encoding_pipeline->GetNext()) {
        profiler.StopTimer("encode");
        output_frames.push_back(frame_transformer(stream_id, *encoded_frame));
      }
    }

    return output_frames;
  }

  ExecutionProfiler& GetExecutionProfiler() { return profiler; }

private:
  std::unique_ptr<DecodingPipeline<FrameType>> decoding_pipeline;
  std::unique_ptr<MultiscalingPipeline<FrameType>> multiscaling_pipeline;
  std::vector<std::unique_ptr<EncodingPipeline<FrameType>>> encoding_pipelines;
  ExecutionProfiler profiler;
  bool flushed;
};
