#pragma once
#include <cstdint>

template <typename T> struct VideoFrame {
  using SequenceID = uint32_t;

  VideoFrame(SequenceID id, T* frame)
      : id(id), frame(frame), is_keyframe(false), frames_gap(0) {}
  VideoFrame(SequenceID id, T* frame, bool is_keyframe)
      : id(id), frame(frame), is_keyframe(is_keyframe), frames_gap(0) {}
  VideoFrame(SequenceID id, T* frame, bool is_keyframe, uint32_t frames_gap)
      : id(id), frame(frame), is_keyframe(is_keyframe), frames_gap(frames_gap) {
  }
  VideoFrame(uint32_t id,
             T* frame,
             bool is_keyframe,
             uint32_t frames_gap,
             bool skip_processing)
      : id(id), frame(frame), is_keyframe(is_keyframe), frames_gap(frames_gap),
        skip_processing(skip_processing) {}

  SequenceID id;
  T* frame;
  bool is_keyframe;
  uint32_t frames_gap;
  bool skip_processing = false;
};
