#pragma once

#include "video_frame.h"
#include <cstdint>
#include <optional>
#include <utility>
#include <vector>

using ScalerOutputID = uint32_t;

struct MultiScalerInput {
  int width;
  int height;
  int framerate;
};

struct MultiScalerOutput {
  ScalerOutputID id;
  int width;
  int height;
  int framerate;
};

template <typename FrameType> class MultiscalingPipeline {
public:
  MultiscalingPipeline(MultiScalerInput input,
                      std::vector<MultiScalerOutput> outputs)
      : input(input), outputs(outputs) {}

  virtual void Process(VideoFrame<FrameType>& frame) = 0;

  virtual void Flush() = 0;

  virtual std::optional<std::pair<ScalerOutputID, VideoFrame<FrameType>>> GetNext() = 0;

  virtual ~MultiscalingPipeline() = default;

protected:
  MultiScalerInput input;
  std::vector<MultiScalerOutput> outputs;
};
