#pragma once

#include <cstdint>
#include <queue>
#include <utility>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

#include "../common.h"
#include "../video_frame.h"

class XilinxTimestampEmitter {
public:
  XilinxTimestampEmitter(bool requires_timestamp_halving,
                         bool requires_offset_halving);

  void OnVideoFrame(const VideoFrame<AVFrame>& frame);

  void SetTimestamps(EncodedFrame& encoded_frame);

private:
  std::queue<std::pair<uint32_t, uint32_t>> pending_frame_gaps;
  std::queue<uint32_t> temporary_timestamp_increments;
  bool requires_timestamp_halving;
  bool requires_offset_halving;
  // When output stream contains B-frames the first DTS value is negative.
  // To match the source stream we need to offset it.
  uint32_t initial_dts_offset;
  uint32_t total_frames = 0;
  uint32_t total_offset = 0;
  uint32_t total_frames_skipped = 0;
};
