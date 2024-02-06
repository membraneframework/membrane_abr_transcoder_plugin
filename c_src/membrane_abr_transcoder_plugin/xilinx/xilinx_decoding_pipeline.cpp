#include "xilinx_decoding_pipeline.h"
#include "xilinx_vcu_decoder_dummy_ctx.h"

#include <stdexcept>

XilinxDecodingPipeline::XilinxDecodingPipeline(int width,
                                               int height,
                                               int bitrate,
                                               int device_id)
    : DecodingPipeline(width, height, bitrate) {

  const AVCodec* dec_codec = avcodec_find_decoder_by_name(DECODER_NAME);
  if (!dec_codec) {
    throw std::runtime_error("Failed to find xilinx decoder");
  }

  decoder = avcodec_alloc_context3(dec_codec);
  if (!decoder) {
    throw std::runtime_error("Failed to allocate xilinx decoder context");
  }

  decoder->pix_fmt = AV_PIX_FMT_YUV420P;
  decoder->profile = FF_PROFILE_H264_HIGH;
  decoder->level = H264_LEVEL_52;
  if (bitrate > -1) {
    decoder->bit_rate = bitrate;
  }
  decoder->width = width;
  decoder->height = height;

  // NOTE: this is a kind of hack as it is not possible to set bitdepth and
  // chroma_mode with public function or without providing extradata to the
  // decoder first, so we hack the struct definition to access `bitdepth` and
  // `chroma_mode` fields as without them the decoder initialization fails
  xilinx_vcu_decoder_dummy_ctx_t* dec_ctx =
      (xilinx_vcu_decoder_dummy_ctx_t*)decoder->priv_data;
  // bitdepth and chrome_mode based on YUV420P
  dec_ctx->bitdepth = 8;
  dec_ctx->chroma_mode = 420;

  /*
   * A dictionary hosting a xilinx device id, the devices are 0-based
   * consecutive indices. Each device has to be initialized before use, which
   * is being done by the `initialize` function on application start.
   *
   * The important part is that once the device id gets specified, the same id
   * must be used by all the elements that are taking part in the same ABR
   * Ladder. By default the id gets assigned to -1 and will default to the
   * first device.
   */
  AVDictionary* dec_dict = nullptr;
  av_dict_set_int(&dec_dict, "lxlnx_hwdev", device_id, 0);
  int ret = avcodec_open2(decoder, dec_codec, &dec_dict);
  av_dict_free(&dec_dict);
  if (ret < 0) {
    avcodec_free_context(&decoder);
    throw std::runtime_error("Failed to open decoder");
  }

  parser = av_parser_init(dec_codec->id);
  if (!parser) {
    avcodec_close(decoder);
    avcodec_free_context(&decoder);
    throw std::runtime_error("Failed to initialize h264 parser");
  }

  pkt = av_packet_alloc();
  decoded_frame = av_frame_alloc();
}

XilinxDecodingPipeline::~XilinxDecodingPipeline() {
  avcodec_close(decoder);
  avcodec_free_context(&decoder);
  av_parser_close(parser);
  av_packet_free(&pkt);
  av_frame_free(&decoded_frame);
}

void XilinxDecodingPipeline::Process(const uint8_t* payload, size_t size) {
  const uint8_t* data = payload;
  size_t data_size = size;

  while (data_size > 0) {
    int ret = av_parser_parse2(parser,
                               decoder,
                               &pkt->data,
                               &pkt->size,
                               data,
                               data_size,
                               AV_NOPTS_VALUE,
                               AV_NOPTS_VALUE,
                               0);
    data += ret;
    data_size -= ret;

    if (pkt->size > 0) {
      if (parser->key_frame) {
        keyframe_positions.push(parsed_packets);
      }

      parsed_packets++;

      if (!any_frame_decode_received && parsed_packets >= MAX_PACKETS_WITHOUT_FRAME) {
        throw std::runtime_error("Reached limit of input packets without any decoded frames");
      }

      ret = avcodec_send_packet(decoder, pkt);
      if (ret < 0) {
        throw std::runtime_error("Failed to pass packet to the decoder");
      }

      any_frame_decode_sent = true;
    }
    av_packet_unref(pkt);
  }

  processed_packets++;
}

void XilinxDecodingPipeline::Flush() {
  if (!any_frame_decode_sent) return;

  int ret = avcodec_send_packet(decoder, NULL);
  if (ret < 0) {
    throw std::runtime_error("Failed to pass packet to the decoder");
  }
}

std::optional<VideoFrame<AVFrame>> XilinxDecodingPipeline::GetNext() {
  av_frame_unref(decoded_frame);
  int ret = avcodec_receive_frame(decoder, decoded_frame);

  if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
    return std::nullopt;
  }

  if (ret < 0) {
    throw std::runtime_error("Failed to decode frame");
  }

  any_frame_decode_received = true;

  bool is_keyframe = false;
  if (keyframe_positions.size() > 0 &&
      keyframe_positions.front() == decoded_frames) {
    is_keyframe = true;
    keyframe_positions.pop();
  }

  int frame_gap = 0;
  if (frame_gap_positions.size() > 0 &&
      frame_gap_positions.front().first == decoded_frames) {
    frame_gap = frame_gap_positions.front().second;
    frame_gap_positions.pop();
  }

  return std::optional{VideoFrame<AVFrame>(
      decoded_frames++, decoded_frame, is_keyframe, frame_gap)};
}

void XilinxDecodingPipeline::OnFrameGap(uint32_t frame_gap) {
  if (frame_gap_positions.size() > 0 &&
      frame_gap_positions.front().first == processed_packets) {
    throw std::runtime_error("Frame gap already set");
  }

  frame_gap_positions.push(std::make_pair(processed_packets, frame_gap));
}

void XilinxDecodingPipeline::OnStreamParameters(const uint8_t* payload,
                                                size_t size) {
  const uint8_t* data = payload;
  size_t data_size = size;

  while (data_size > 0) {
    int ret = av_parser_parse2(parser,
                               decoder,
                               &pkt->data,
                               &pkt->size,
                               data,
                               data_size,
                               AV_NOPTS_VALUE,
                               AV_NOPTS_VALUE,
                               0);
    if (pkt->size > 0) {
      throw std::runtime_error("Did not expect h264 parameters to produce a valid h264 packet");
    }

    data += ret;
    data_size -= ret;

    av_packet_unref(pkt);
  }
}
