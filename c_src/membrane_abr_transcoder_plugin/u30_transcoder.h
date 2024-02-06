#pragma once

#include <cstdlib>
#include <memory>

extern "C" {
#include <libavformat/avformat.h>
}

#include "common.h"
#include "transcoding_pipeline.h"

struct stream_frame;

typedef struct ABRTranscoderState {
  bool initialized;
  bool flushed;

  std::unique_ptr<TranscodingPipeline<AVFrame, stream_frame>>
      transcoding_pipeline;
} State;

#include "_generated/u30_transcoder.h"
