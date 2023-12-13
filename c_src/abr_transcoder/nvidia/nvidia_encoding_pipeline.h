#pragma once

#include <memory>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

#include "../encoding_pipeline.h"
#include "nvidia_timestamp_emitter.h"
#include "nvidia_device_context.h"
#include <optional>

class NvidiaEncodingPipeline : public EncodingPipeline<AVFrame> {
  static constexpr const char* ENCODER_NAME = "h264_nvenc";
  // The lowest H264 level supporting FHD streams up to 60FPS
  // https://en.wikipedia.org/wiki/Advanced_Video_Coding#Levels
  static constexpr int H264_LEVEL_42 = 42;
public:
  NvidiaEncodingPipeline(uint32_t output_id, int width,
                         int height,
                         int framerate,
                         int bitrate,
                         const NvidiaTimestampEmitter& timestamp_emitter,
                         std::shared_ptr<NvidiaDeviceContext> device_context
                         );

  virtual void Process(VideoFrame<AVFrame>& frame) override;

  virtual void Flush() override;

  virtual std::optional<EncodedFrame> GetNext() override;

  virtual ~NvidiaEncodingPipeline();

private:
  NvidiaTimestampEmitter timestamp_emitter;
  std::shared_ptr<NvidiaDeviceContext> device_context;
  AVCodecContext* encoder;
  AVPacket* pkt;

  uint32_t encoded_frames = 0;
  bool first_frame_processed = false;
};
