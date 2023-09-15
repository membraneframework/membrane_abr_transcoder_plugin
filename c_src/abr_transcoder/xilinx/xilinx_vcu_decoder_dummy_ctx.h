#pragma once

#include <xma.h>
#include <xmaplugin.h>
#include <xrm.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/fifo.h>
}

#define MAX_DEC_PARAMS 11

typedef struct xilinx_vcu_decoder_dummy_ctx_t {
  const AVClass* _class;
  XmaDecoderSession* dec_session;
  char dec_params_name[MAX_DEC_PARAMS][100];
  XmaParameter dec_params[MAX_DEC_PARAMS];
  xrmContext* xrm_ctx;
  xrmCuListResourceV2 decode_cu_list_res;
  bool decode_res_inuse;
  XmaDataBuffer buffer;
  XmaFrame xma_frame;
  XmaFrameProperties props;
  AVCodecContext* avctx;
  bool flush_sent;
  int lxlnx_hwdev;
  uint32_t bitdepth;
  uint32_t codec_type;
  uint32_t low_latency;
  uint32_t entropy_buffers_count;
  uint32_t latency_logging;
  uint32_t splitbuff_mode;
  int first_idr_found;
  int** pkt_fifo;
  int64_t genpts;
  AVRational pts_q;
  uint32_t chroma_mode;
} xilinx_vcu_decoder_dummy_ctx_t;
