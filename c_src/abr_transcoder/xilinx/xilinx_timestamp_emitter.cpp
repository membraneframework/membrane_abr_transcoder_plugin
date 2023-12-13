#include "xilinx_timestamp_emitter.h"

#include <stdexcept>

XilinxTimestampEmitter::XilinxTimestampEmitter(bool requires_timestamp_halving,
                                               bool requires_offset_halving)
    : requires_timestamp_halving(requires_timestamp_halving),
      requires_offset_halving(requires_offset_halving) {
  total_offset = 0;
  if (requires_timestamp_halving) {
    initial_dts_offset = 2;
  } else {
    initial_dts_offset = 1;
  }
}

void XilinxTimestampEmitter::OnVideoFrame(const VideoFrame<AVFrame>& frame) {
  if (frame.skip_processing) {
    total_frames_skipped++;

    // NOTE: It happens that when you skip a frame and then pass the next one to the encoder,
    // the timestamps get incremented only after this next frame (when leaving encoder) but in fact it needs to be
    // incremented too. To adjust for that phenomenon we schedule the temporary timestamp increment just for the next frame.
    temporary_timestamp_increments.push(frame.id + 1 - total_frames_skipped);
  }

  if (frame.frames_gap > 0) {
    pending_frame_gaps.push(
        std::make_pair(frame.id - total_frames_skipped, frame.frames_gap));
  }
}

void XilinxTimestampEmitter::SetTimestamps(EncodedFrame& encoded_frame) {
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

  if (temporary_timestamp_increments.size() > 0) {
    auto increment_for_frame = temporary_timestamp_increments.front();
    if (increment_for_frame < frame_num) {
      throw std::runtime_error(
          "Missed the temporary frame timestamps increment");
    }

    if (increment_for_frame == frame_num) {
      encoded_frame.dts += requires_timestamp_halving ? 2 : 1;
      encoded_frame.pts += requires_offset_halving ? 2 : 1;

      temporary_timestamp_increments.pop();
    }
  }

  int dts = encoded_frame.dts;
  int pts = encoded_frame.pts;

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
