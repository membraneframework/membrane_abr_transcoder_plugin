#include "nvidia_encoding_pipeline.h"
#include <memory>
#include <stdexcept>
#include <spdlog/spdlog.h>

extern "C" {
    #include <libavutil/error.h>
    #include <libavutil/opt.h>
}

NvidiaEncodingPipeline::NvidiaEncodingPipeline(
    uint32_t output_id,
    int width,
    int height,
    int framerate,
    int bitrate,
    const NvidiaTimestampEmitter& timestamp_emitter,
    std::shared_ptr<NvidiaDeviceContext> device_context)
    : EncodingPipeline(output_id, width, height, framerate, bitrate),
      timestamp_emitter(timestamp_emitter), device_context(device_context) {
  auto* enc_codec = avcodec_find_encoder_by_name(ENCODER_NAME);
  if (!enc_codec) {
    throw std::runtime_error("Failed to find nvidia encoder");
  }

  pkt = av_packet_alloc();

  spdlog::debug("Initializing encoder id = {}", output_id);
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

  int max_b_frames = 2;
  encoder->max_b_frames = max_b_frames;
  encoder->pix_fmt = AV_PIX_FMT_CUDA;

  encoder->hw_frames_ctx = av_buffer_ref(device_context->GetFramesContext(output_id));

  // set profile to high
  av_opt_set(encoder->priv_data, "profile", "high", 0);
  // constant bitrate rate control
  if (bitrate > -1) {
    av_opt_set(encoder->priv_data, "rc", "cbr", 0);
  }
  // preset low latency + high quality
  av_opt_set(encoder->priv_data, "preset", "p4", 0);
  // tune for low latency
  av_opt_set(encoder->priv_data, "tune", "ll", 0);

  AVDictionary* enc_dict = NULL;
  // number of allowed consecutive B-frames
  av_dict_set_int(&enc_dict, "forced-idr", 1, 0);

  if (avcodec_open2(encoder, enc_codec, &enc_dict) < 0) {
    av_packet_free(&pkt);
    avcodec_free_context(&encoder);
    av_dict_free(&enc_dict);

    throw std::runtime_error("Failed to open a encoder context");
  }

  spdlog::debug("Encoder initialized id = {}", output_id);

  av_dict_free(&enc_dict);
}

NvidiaEncodingPipeline::~NvidiaEncodingPipeline() {
  avcodec_close(encoder);
  avcodec_free_context(&encoder);
  av_packet_free(&pkt);
}

void NvidiaEncodingPipeline::Process(VideoFrame<AVFrame>& frame) {
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

void NvidiaEncodingPipeline::Flush() {
  if (!first_frame_processed)
    return;

  int ret = avcodec_send_frame(encoder, NULL);
  if (ret < 0) {
    throw std::runtime_error("Failed to flush the encoder");
  }
}

std::optional<EncodedFrame> NvidiaEncodingPipeline::GetNext() {
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
