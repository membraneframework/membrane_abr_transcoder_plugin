#pragma once
#include <cstdint>
#include <optional>

#include "video_frame.h"

template <typename FrameType> class DecodingPipeline {
public:
  DecodingPipeline(int width, int height, int bitrate)
      : width(width), height(height), bitrate(bitrate) {}

  virtual void Process(const uint8_t* payload, size_t size) = 0;

  virtual void Flush() = 0;

  virtual std::optional<VideoFrame<FrameType>> GetNext() = 0;

  virtual void OnFrameGap(uint32_t frame_gap) = 0;

  virtual void OnStreamParameters(const uint8_t* payload, size_t size) = 0;

  virtual ~DecodingPipeline() = default;

protected:
  int width;
  int height;
  int bitrate;
};
