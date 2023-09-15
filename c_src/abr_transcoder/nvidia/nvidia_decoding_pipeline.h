#pragma once

#include <queue>
#include <memory>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/fifo.h>
}

#include "../decoding_pipeline.h"
#include "nvidia_device_context.h"


// The lowest H264 level supporting FHD streams up to 60FPS
// https://en.wikipedia.org/wiki/Advanced_Video_Coding#Levels

class NvidiaDecodingPipeline : public DecodingPipeline<AVFrame> {
  static constexpr int MAX_PACKETS_WITHOUT_FRAME = 100;
  static constexpr const char* DECODER_NAME = "h264_cuvid";
  static constexpr int H264_LEVEL_42 = 42;
public:
  NvidiaDecodingPipeline(int width, int height, int framerate, int bitrate, std::shared_ptr<NvidiaDeviceContext> device_context);

  virtual void Process(const uint8_t* payload, size_t size) override;

  virtual void Flush() override;

  virtual void OnFrameGap(uint32_t frame_gap) override;

  virtual void OnStreamParameters(const uint8_t* payload, size_t size) override;

  virtual std::optional<VideoFrame<AVFrame>> GetNext() override;

  virtual ~NvidiaDecodingPipeline();

private:
  // h264 parser
  std::shared_ptr<NvidiaDeviceContext> _device_context;
  AVCodecParserContext* parser;
  // video decoding context
  AVCodecContext* decoder;
  AVFrame* decoded_frame;
  // NOTE: we need a single software video frame
  // as the Nvidia transcoding pipeline currently doesn't support
  // keeping everything on GPU, so after decoding we need to once againt transform the frame
  // to host memory.
  AVFrame* sw_frame;
  AVPacket* pkt;


  bool any_frame_decode_sent = false;
  bool any_frame_decode_received = false;
  int parsed_packets = 0;
  int processed_packets = 0;
  int decoded_frames = 0;
  std::queue<int> keyframe_positions;
  std::queue<std::pair<int, int>> frame_gap_positions;
};
