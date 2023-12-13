#pragma once

#include <optional>
#include <deque>
#include <queue>
#include <utility>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
}

#include "../multiscaling_pipeline.h"
#include "../video_frame.h"

class XilinxMultiscalingPipeline : public MultiscalingPipeline<AVFrame> {
  using FrameGap = uint32_t;
  using FrameNumber = uint32_t;

public:
  XilinxMultiscalingPipeline(MultiScalerInput input,
                            std::vector<MultiScalerOutput> outputs,
                            int device_id);

  virtual void Process(VideoFrame<AVFrame>& frame) override;

  virtual void Flush() override;

  virtual std::optional<std::pair<ScalerOutputID, VideoFrame<AVFrame>>>
  GetNext() override;

  virtual ~XilinxMultiscalingPipeline();

  bool RequiresTimestampHalving(ScalerOutputID output_id) const;

  bool RequiresOffsetHalving(ScalerOutputID output_id) const;

private:
  void EnqueueKeyFrame(const VideoFrame<AVFrame>& frame);
  bool DequeueKeyFrame(ScalerOutputID output_id, FrameNumber frame_num);
  void EnqueueFrameGap(const VideoFrame<AVFrame>& frame);
  uint32_t DequeueFrameGap(ScalerOutputID output_id, FrameNumber frame_num);
  void EnqueueFrameSkip(ScalerOutputID output_id, FrameNumber frame_num);
  bool DequeueFrameSkip(ScalerOutputID output_id, FrameNumber frame_num);

private:
  AVFilterContext* buffer_source;
  AVFilterGraph* graph;
  std::vector<AVFilterContext*> buffer_sinks;

  std::vector<uint32_t> scaled_frame_counts;

  std::vector<std::deque<FrameNumber>> keyframe_positions;
  std::vector<std::queue<std::pair<FrameNumber, FrameGap>>>
      frame_gap_positions;
  std::vector<std::queue<FrameNumber>> skip_frame_positions;

  bool input_half_rate_filter_applied;
  bool any_half_rate_filter_applied;
  std::vector<bool> output_half_rate_filter_applied;

  int last_pts = 0;
  AVFrame* scaled_frame = av_frame_alloc();
  ScalerOutputID currently_read_output = 0;

  uint32_t repeated_input_frames = 0;
  std::optional<VideoFrame<AVFrame>> last_input_frame = std::nullopt;
};
