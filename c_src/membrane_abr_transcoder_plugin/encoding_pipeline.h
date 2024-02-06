#pragma once
#include <cstdint>
#include <optional>

#include "common.h"
#include "video_frame.h"

template <typename FrameType> class EncodingPipeline {
public:
  EncodingPipeline(uint32_t output_id, int width, int height, int framerate, int bitrate)
      : output_id(output_id), width(width), height(height), framerate(framerate), bitrate(bitrate) {}

  virtual void Process(VideoFrame<FrameType>& frame) = 0;

  virtual void Flush() = 0;

  virtual std::optional<EncodedFrame> GetNext() = 0;

  virtual ~EncodingPipeline() = default;

  uint32_t GetOutputID() { return output_id; }
protected:
  uint32_t output_id;
  int width;
  int height;
  int framerate;
  int bitrate;
};
