#pragma once

#include "video_frame.h"
#include <cstdint>
#include <optional>
#include <utility>
#include <vector>

using ScalerOutputID = size_t;

struct MultiScalerInput {
  int width;
  int height;
  int framerate;
};

struct MultiScalerOutput {
  int id;
  int width;
  int height;
  int framerate;
};

template <typename T> class MultiScalerPipeline {
public:
  MultiScalerPipeline(MultiScalerInput input,
                      std::vector<MultiScalerOutput> outputs)
      : input(input), outputs(outputs) {}

  virtual void Process(VideoFrame<T>& frame) = 0;

  virtual void Flush() = 0;

  virtual std::optional<std::pair<ScalerOutputID, VideoFrame<T>>> GetNext() = 0;

  virtual ~MultiScalerPipeline() = default;

protected:
  MultiScalerInput input;
  std::vector<MultiScalerOutput> outputs;
};
