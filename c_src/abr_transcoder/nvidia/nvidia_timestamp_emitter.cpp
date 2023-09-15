#include "nvidia_timestamp_emitter.h"

#include <stdexcept>

NvidiaTimestampEmitter::NvidiaTimestampEmitter(bool requires_timestamp_halving,
                                               bool requires_offset_halving)
    : requires_timestamp_halving(requires_timestamp_halving),
      requires_offset_halving(requires_offset_halving) {
  total_offset = 0;
  initial_dts_offset = 2;
}

void NvidiaTimestampEmitter::OnVideoFrame(const VideoFrame<AVFrame>& frame) {
  if (frame.skip_processing) {
    total_frames_skipped++;
  }

  if (frame.frames_gap > 0) {
    pending_frame_gaps.push(std::make_pair(frame.id - total_frames_skipped, frame.frames_gap));
  }
}

void NvidiaTimestampEmitter::SetTimestamps(EncodedFrame& encoded_frame) {
  uint32_t frame_num = total_frames++;

  if (pending_frame_gaps.size() > 0) {
    auto [gap_frame_num, gap] = pending_frame_gaps.front();
    if (gap_frame_num < frame_num) {
      throw std::runtime_error("Missed the encoder's frame gap assignment");
    }

    if (gap_frame_num == frame_num) {
      pending_frame_gaps.pop();
      total_offset += gap;
    }
  }

  uint32_t dts = encoded_frame.dts;
  uint32_t pts = encoded_frame.pts;

  uint32_t offset = total_offset;
  if (requires_offset_halving) {
    offset /= 2;
  }

  dts += initial_dts_offset;
  dts += offset;
  pts += offset;

  if (requires_timestamp_halving) {
    dts /= 2;
    pts /= 2;
  }

  encoded_frame.dts = dts;
  encoded_frame.pts = pts;
}
