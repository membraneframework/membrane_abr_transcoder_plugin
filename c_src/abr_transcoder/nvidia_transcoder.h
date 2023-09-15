#pragma once

#include <memory>

extern "C" {
#include <libavformat/avformat.h>
}

#include "transcoding_pipeline.h"

struct stream_frame;

typedef struct ABRTranscoderState {
  std::unique_ptr<TranscodingPipeline<AVFrame, stream_frame>> transcoding_pipeline;
} State;

#include "_generated/nvidia_transcoder.h"
