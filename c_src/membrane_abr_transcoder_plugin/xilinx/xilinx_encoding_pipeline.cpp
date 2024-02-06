
#include "xilinx_encoding_pipeline.h"
#include <stdexcept>

XilinxEncodingPipeline::XilinxEncodingPipeline(
    uint32_t output_id,
    int width,
    int height,
    int framerate,
    int bitrate,
    int device_id,
    const XilinxTimestampEmitter& timestamp_emitter)
    : EncodingPipeline(output_id, width, height, framerate, bitrate),
      timestamp_emitter(timestamp_emitter) {
  auto* enc_codec = avcodec_find_encoder_by_name(ENCODER_NAME);
  if (!enc_codec) {
    throw std::runtime_error("Failed to find xilinx encoder");
  }

  pkt = av_packet_alloc();

  encoder = avcodec_alloc_context3(enc_codec);
  if (!encoder) {
    av_packet_free(&pkt);
    throw std::runtime_error("Failed to create encoder context");
  }

  encoder->level = H264_LEVEL_42;
  if (bitrate > -1) {
    encoder->bit_rate = bitrate;
  }
  encoder->width = width;
  encoder->height = height;

  encoder->time_base = (AVRational){1, framerate};
  encoder->framerate = (AVRational){framerate, 1};

  // we want to emit a key frame every 2 seconds
  encoder->gop_size = KEYFRAME_INTERVAL * framerate;
  int max_b_frames = 2;
  encoder->max_b_frames = max_b_frames;
  encoder->pix_fmt = AV_PIX_FMT_XVBM_8;

  AVDictionary* enc_dict = NULL;
  // number of allowed consecutive B-frames
  av_dict_set_int(&enc_dict, "bf", max_b_frames, 0);
  // maximum bitrate allowed by the encoder
  if (bitrate > -1) {
    av_dict_set_int(&enc_dict, "max-bitrate", bitrate, 0);
  }
  // h264 level
  av_dict_set_int(&enc_dict, "level", H264_LEVEL_42, 0);
  // the device id onto which the encoder should be placed
  av_dict_set_int(&enc_dict, "lxlnx_hwdev", device_id, 0);

  if (avcodec_open2(encoder, enc_codec, &enc_dict) < 0) {
    av_packet_free(&pkt);
    avcodec_free_context(&encoder);
    av_dict_free(&enc_dict);

    throw std::runtime_error("Failed to open a encoder context");
  }

  av_dict_free(&enc_dict);
}

XilinxEncodingPipeline::~XilinxEncodingPipeline() {
  avcodec_close(encoder);
  avcodec_free_context(&encoder);
  av_packet_free(&pkt);
}

void XilinxEncodingPipeline::Process(VideoFrame<AVFrame>& frame) {
  timestamp_emitter.OnVideoFrame(frame);

  if (frame.skip_processing) {
    return;
  }

  int ret = avcodec_send_frame(encoder, frame.frame);
  if (ret < 0) {
    throw std::runtime_error("Failed to encode a frame");
  }

  first_frame_processed = true;
}

void XilinxEncodingPipeline::Flush() {
  if (!first_frame_processed)
    return;

  int ret = avcodec_send_frame(encoder, NULL);
  if (ret < 0) {
    throw std::runtime_error("Failed to flush the encoder");
  }
}

std::optional<EncodedFrame> XilinxEncodingPipeline::GetNext() {
  av_packet_unref(pkt);
  int ret = avcodec_receive_packet(encoder, pkt);
  if (ret == 0) {
    EncodedFrame frame;
    frame.size = pkt->size;
    frame.data = pkt->data;
    frame.dts = pkt->dts;
    frame.pts = pkt->pts;

    timestamp_emitter.SetTimestamps(frame);
    encoded_frames++;
    return std::optional{frame};
  }

  if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) {
    throw std::runtime_error("Failed to encode a frame");
  }

  return std::nullopt;
}
