#pragma once

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

#include "../encoding_pipeline.h"
#include "xilinx_timestamp_emitter.h"
#include <optional>

class XilinxEncodingPipeline : public EncodingPipeline<AVFrame> {
  static constexpr const char* ENCODER_NAME = "mpsoc_vcu_h264";
  // The lowest H264 level supporting FHD streams up to 60FPS
  // https://en.wikipedia.org/wiki/Advanced_Video_Coding#Levels
  static constexpr int H264_LEVEL_42 = 42;
  // keyframe interval in seconds
  static constexpr int KEYFRAME_INTERVAL = 2;
public:
  XilinxEncodingPipeline(uint32_t output_id, int width,
                         int height,
                         int framerate,
                         int bitrate,
                         int device_id,
                         const XilinxTimestampEmitter& timestamp_emitter);

  virtual void Process(VideoFrame<AVFrame>& frame) override;

  virtual void Flush() override;

  virtual std::optional<EncodedFrame> GetNext() override;

  virtual ~XilinxEncodingPipeline();

private:
  AVCodecContext* encoder;
  AVPacket* pkt;

  XilinxTimestampEmitter timestamp_emitter;
  uint32_t encoded_frames = 0;
  bool first_frame_processed = false;
  bool increment_timestamps_on_next_frame = false;
};
