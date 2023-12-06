#include "nvidia_decoding_pipeline.h"

#include <stdexcept>

NvidiaDecodingPipeline::NvidiaDecodingPipeline(int width,
                                               int height,
                                               int framerate,
                                               int bitrate, std::shared_ptr<NvidiaDeviceContext> device_context)
    : DecodingPipeline(width, height, bitrate), _device_context{device_context} {

  const AVCodec* dec_codec = avcodec_find_decoder_by_name(DECODER_NAME);
  if (!dec_codec) {
    throw std::runtime_error("Failed to find nvidia decoder");
  }

  decoder = avcodec_alloc_context3(dec_codec);
  if (!decoder) {
    throw std::runtime_error("Failed to allocate nvidia decoder context");
  }

  decoder->hw_device_ctx = av_buffer_ref(_device_context->GetDeviceContext());
  decoder->flags |= AV_CODEC_FLAG_LOW_DELAY;
  decoder->time_base = {1, framerate};
  decoder->pkt_timebase = {1, framerate};

  decoder->profile = FF_PROFILE_H264_HIGH;
  decoder->level = H264_LEVEL_52;
  if (bitrate > -1) {
    decoder->bit_rate = bitrate;
  }
  decoder->width = width;
  decoder->height = height;


  int ret = avcodec_open2(decoder, dec_codec, nullptr);
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
  sw_frame = av_frame_alloc();
}

NvidiaDecodingPipeline::~NvidiaDecodingPipeline() {
  avcodec_close(decoder);
  avcodec_free_context(&decoder);
  av_parser_close(parser);
  av_packet_free(&pkt);
  av_frame_free(&decoded_frame);
}

void NvidiaDecodingPipeline::Process(const uint8_t* payload, size_t size) {
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

void NvidiaDecodingPipeline::Flush() {
  if (!any_frame_decode_sent) return;

  int ret = avcodec_send_packet(decoder, NULL);
  if (ret < 0) {
    throw std::runtime_error("Failed to pass packet to the decoder");
  }
}

std::optional<VideoFrame<AVFrame>> NvidiaDecodingPipeline::GetNext() {
  av_frame_unref(decoded_frame);
  av_frame_unref(sw_frame);
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

  if (av_hwframe_transfer_data(sw_frame, decoded_frame, 0) < 0) {
    throw std::runtime_error("Failed to transfer frame to system memory");
  }

  return std::optional{VideoFrame<AVFrame>(
      decoded_frames++, sw_frame, is_keyframe, frame_gap)};
}

void NvidiaDecodingPipeline::OnFrameGap(uint32_t frame_gap) {
  if (frame_gap_positions.size() > 0 &&
      frame_gap_positions.front().first == processed_packets) {
    throw std::runtime_error("Frame gap already set");
  }

  frame_gap_positions.push(std::make_pair(processed_packets, frame_gap));
}

void NvidiaDecodingPipeline::OnStreamParameters(const uint8_t* payload,
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
