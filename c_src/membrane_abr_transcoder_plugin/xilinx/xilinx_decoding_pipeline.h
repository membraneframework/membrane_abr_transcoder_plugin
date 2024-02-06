#pragma once

#include <queue>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/fifo.h>
}

#include "../decoding_pipeline.h"

// The lowest H264 level supporting FHD streams up to 60FPS and QuickSync
// https://en.wikipedia.org/wiki/Advanced_Video_Coding#Levels

class XilinxDecodingPipeline : public DecodingPipeline<AVFrame> {
  static constexpr int MAX_PACKETS_WITHOUT_FRAME = 100;
  static constexpr const char* DECODER_NAME = "mpsoc_vcu_h264";
  static constexpr int H264_LEVEL_52 = 52;
public:
  XilinxDecodingPipeline(int width, int height, int bitrate, int device_id);

  virtual void Process(const uint8_t* payload, size_t size) override;

  virtual void Flush() override;

  virtual void OnFrameGap(uint32_t frame_gap) override;

  virtual void OnStreamParameters(const uint8_t* payload, size_t size) override;

  virtual std::optional<VideoFrame<AVFrame>> GetNext() override;

  virtual ~XilinxDecodingPipeline();

private:
  // h264 parser
  AVCodecParserContext* parser;
  // video decoding context
  AVCodecContext* decoder;
  AVFrame* decoded_frame;
  AVPacket* pkt;


  bool any_frame_decode_sent = false;
  bool any_frame_decode_received = false;
  int parsed_packets = 0;
  int processed_packets = 0;
  int decoded_frames = 0;
  std::queue<int> keyframe_positions;
  std::queue<std::pair<int, int>> frame_gap_positions;
};
