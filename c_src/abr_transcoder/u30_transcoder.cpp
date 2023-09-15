#include "u30_transcoder.h"

#include <cstring>
#include <utility>

#include "multiscaling_pipeline.h"
#include "xilinx/xilinx_decoding_pipeline.h"
#include "xilinx/xilinx_encoding_pipeline.h"
#include "xilinx/xilinx_multiscaling_pipeline.h"
#include "xilinx/xilinx_timestamp_emitter.h"

// FFmpeg related imports
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/fifo.h>
#include <libavutil/opt.h>
}

// Xilinx related imports
#include <xma.h>
#include <xmaplugin.h>
#include <xrm.h>

#define MAX_OUTPUTS 4

void handle_destroy_state(UnifexEnv* env, UnifexState* state) {
  UNIFEX_UNUSED(env);

  state->~State();
}

#include <vector>

UNIFEX_TERM create(UnifexEnv* env,
                   int64_t device_id,
                   abr_stream_params original_stream_params,
                   abr_stream_params* target_streams,
                   unsigned int target_streams_length) {
  if (target_streams_length > MAX_OUTPUTS || target_streams_length < 1) {
    return create_result_error(env, "invalid number of outputs");
  }

  State* state = unifex_alloc_state(env);
  state = new (state) State();

  UNIFEX_TERM result;

  try {
    std::unique_ptr<DecodingPipeline<AVFrame>> decoding_pipeline =
        std::make_unique<XilinxDecodingPipeline>(original_stream_params.width,
                                                 original_stream_params.height,
                                                 original_stream_params.bitrate,
                                                 device_id);

    MultiScalerInput multiscaler_input = {original_stream_params.width,
                                          original_stream_params.height,
                                          original_stream_params.framerate};
    std::vector<MultiScalerOutput> multiscaler_outputs;

    for (unsigned int i = 0; i < target_streams_length; i++) {
      multiscaler_outputs.push_back({i,
                                     target_streams[i].width,
                                     target_streams[i].height,
                                     target_streams[i].framerate});
    }

    std::unique_ptr<MultiscalingPipeline<AVFrame>> multiscaling_pipeline =
        std::make_unique<XilinxMultiscalingPipeline>(
            multiscaler_input, multiscaler_outputs, device_id);

    std::vector<std::unique_ptr<EncodingPipeline<AVFrame>>> encoding_pipelines;
    for (unsigned int i = 0; i < target_streams_length; i++) {

      auto xilinx_multiscaling_pipeline =
          dynamic_cast<XilinxMultiscalingPipeline*>(
              multiscaling_pipeline.get());
      auto timestamp_emitter = XilinxTimestampEmitter(
          xilinx_multiscaling_pipeline->RequiresTimestampHalving(i),
          xilinx_multiscaling_pipeline->RequiresOffsetHalving(i));

      std::unique_ptr<EncodingPipeline<AVFrame>> encoding_pipeline =
          std::make_unique<XilinxEncodingPipeline>(i,
                                                   target_streams[i].width,
                                                   target_streams[i].height,
                                                   target_streams[i].framerate,
                                                   target_streams[i].bitrate,
                                                   device_id,
                                                   timestamp_emitter);

      encoding_pipelines.push_back(std::move(encoding_pipeline));
    }

    state->transcoding_pipeline =
        std::make_unique<TranscodingPipeline<AVFrame, stream_frame>>(
            std::move(decoding_pipeline),
            std::move(multiscaling_pipeline),
            std::move(encoding_pipelines));

    /*
    ⣿⣿⣿⣿⣿⣿⣿⣿⡿⠋⠁⠀⠉⠙⠛⠿⠛⠉⠀⠀⠀⠉⢻⣿⣿⣿⣿⣿⣿⣿
    ⣿⣿⣿⣿⣿⣿⡿⠋⠀⢀⠔⠒⠒⠒⠒⠀⠠⠔⠚⠉⠉⠁⠀⠙⢿⣿⣿⣿⣿⣿
    ⣿⣿⣿⣿⠟⢋⠀⠀⠀⠀⣠⢔⠤⠀⢤⣤⡀⠠⣢⡭⠋⡙⢿⣭⡨⠻⣿⣿⣿⣿
    ⣿⣿⣿⠇⢀⠆⠀⠀⠀⣪⣴⣿⠐⢬⠀⣿⡗⣾⣿⡇⠈⠦⢸⣿⠗⢠⠿⠿⣿⣿
    ⣿⣿⡏⠀⠀⠀⢀⡀⠀⠈⠛⠻⠄⠀⠠⠋⠀⠈⠛⠻⠆⠀⠈⢀⡠⣬⣠⢣⣶⢸
    ⣿⡿⠀⠀⠀⣶⡌⣇⣿⢰⠷⠦⠄⣀⣀⣀⣀⣀⣀⣠⣤⠶⠞⡛⠁⣿⣿⣾⣱⢸
    ⣿⡇⠀⠀⠀⣬⣽⣿⣿⢸⡜⢿⣷⣶⣶⣶⣯⣽⣦⡲⣾⣿⡇⣿⠀⣌⠿⣿⠏⣼
    ⣿⡇⠀⠀⠀⠹⣿⡿⢫⡈⠻⢦⡹⢟⣛⣛⣛⣛⣛⣡⠿⣫⡼⠃⠀⣿⡷⢠⣾⣿
    ⣿⡇⡀⠀⠀⠀⠀⠰⣿⣷⡀⠀⠙⠳⠦⣭⣭⣭⣵⡶⠿⠋⠀⢀⣴⣿⡇⣾⣿⣿
    ⣿⢠⣿⣦⣄⣀⠀⠀⢻⣿⣧⠀⠀⠀⠀⠀⠀⠀⠀⠀ ⣀⣤⣶⣿⣿⡟⣰⣿⣿
    ⡇⣸⣿⣿⣿⣿⣿⣷⣦⢹⣿⣇⢠⣤⣤⣤⣤⣶⣾⣿⣿⣿⣿⣿⣿⡇⢹⣿⣿⣿
    ⡇⣿⣿⣿⣿⣿⣿⣿⣿⣎⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠏⣸⣿⣿⣿
    ⣧⡘⠿⢿⣿⣿⣿⣿⣿⣿⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠟⢋⣡⣾⣿⣿⣿⣿
    ⣿⣿⣿⣶⣤⣍⣉⣛⣛⡛⠛⠛⢛⣛⣛⣛⣛⣉⣩⣭⣤⣴⣶⣿⣿⣿⣿⣿⣿⣿
    */

    state->initialized = 1;
    result = create_result_ok(env, state);
  } catch (std::exception& e) {
    result = create_result_error(env, e.what());
  }

  unifex_release_state(env, state);
  return result;
}

UNIFEX_TERM update_sps_and_pps(UnifexEnv* env,
                   UnifexPayload* sps_and_pps, UnifexState* state) {
  state->transcoding_pipeline->OnStreamParameters(sps_and_pps->data, sps_and_pps->size);

  return update_sps_and_pps_result_ok(env);
}

stream_frame encoded_frame_to_stream_frame(UnifexEnv* env,
                                           uint32_t output_id,
                                           EncodedFrame encoded_frame) {
  UnifexPayload* new_payload =
      (UnifexPayload*)unifex_alloc(sizeof(UnifexPayload));
  unifex_payload_alloc(
      env, UNIFEX_PAYLOAD_BINARY, encoded_frame.size, new_payload);
  memcpy(new_payload->data, encoded_frame.data, encoded_frame.size);

  stream_frame frame;
  frame.id = output_id;
  frame.payload = new_payload;
  frame.pts = encoded_frame.pts;
  frame.dts = encoded_frame.dts;

  return frame;
}

/*
 * Processes a H264 frame and produces a number of output frames
 * that are accordingly scaled and encoded.
 *
 * To make sure that the transcoded output frames are aligned keyframe and
 * timestamp wise the function takes into consideration the number of frames
 * that were dropped between input frames.
 *
 * @param env Unifex environment.
 * @param payload Unifex payload containing the H264 frame.
 * @param frames_gap Number of frames that were dropped just before this frame.
 * @param state Unifex state.
 * @return Unifex term that encodes the processed result.
 */
UNIFEX_TERM process(UnifexEnv* env,
                    UnifexPayload* payload,
                    int frames_gap,
                    UnifexState* state) {
  UNIFEX_TERM result;

  unsigned char* data = payload->data;
  int data_size = payload->size;

  std::vector<stream_frame> stream_frames;

  if (frames_gap > 0) {
    state->transcoding_pipeline->OnFrameGap((uint32_t)frames_gap);
  }

  try {
    stream_frames = state->transcoding_pipeline->Process(
        data,
        data_size,
        [&env](uint32_t output_id, EncodedFrame encoded_frame) -> stream_frame {
          return encoded_frame_to_stream_frame(env, output_id, encoded_frame);
        });

    result = process_result_ok(env, stream_frames.data(), stream_frames.size());
  } catch (const std::exception& e) {
    result = process_result_error(env, e.what());
  }

  for (size_t i = 0; i < stream_frames.size(); i++) {
    unifex_payload_release(stream_frames[i].payload);
  }

  return result;
}

/*
 * Flushes every encoder and potentially reduces leftover frames.
 */
UNIFEX_TERM flush(UnifexEnv* env, UnifexState* state) {
  UNIFEX_TERM result;

  if (!state->initialized || state->flushed) {
    return flush_result_ok(env, nullptr, 0);
  }

  state->flushed = true;

  std::vector<stream_frame> stream_frames;

  try {
    stream_frames = state->transcoding_pipeline->Flush(
        [&env](int stream_id, EncodedFrame encoded_frame) -> stream_frame {
          return encoded_frame_to_stream_frame(env, stream_id, encoded_frame);
        });

    result = flush_result_ok(env, stream_frames.data(), stream_frames.size());
  } catch (const std::exception& e) {
    result = flush_result_error(env, e.what());
  }

  for (size_t i = 0; i < stream_frames.size(); i++) {
    unifex_payload_release(stream_frames[i].payload);
  }

  return result;
}

//////////////////////////////////////////////////
/////////////// XMA INITIALIZATION ///////////////
//////////////////////////////////////////////////

#define XLNX_XCLBIN_PATH "/opt/xilinx/xcdr/xclbins/transcode.xclbin"
// A single U30 card has only 2 devices, if the transcoder is supposed to be
// used with more than 1 card then change the constant below.
#define MAX_XLNX_DEVS 2

#include <dlfcn.h>

/*
 * Initializes the U30 card and the Xilinx Video SDK.
 *
 * The function must be called only ONCE per application run, before any other
 * function from the following NIF gets called.
 *
 * Due to unknown reasons, before initializing the Xilinx Video SDK we need
 * to manually load a 'libxma2api.so` shared library.
 *
 * Without loading the mentioned library first, the further initialization of
 * the SDK fails with SEGFAULT as it is unable to properly initialize the
 * library on first load. Loading it manually, before the SDK does it, somehow
 * fixes the problem and the SDK gets initialized properly.
 */
UNIFEX_TERM initialize(UnifexEnv* env, int devices) {
  av_log_set_level(AV_LOG_WARNING);

  if (devices < 0 || devices > MAX_XLNX_DEVS) {
    char error[128];
    snprintf(error,
             sizeof(error),
             "requested to initialize %d devices but only %d are available",
             devices,
             MAX_XLNX_DEVS);
    return initialize_result_error(env, error);
  }

  XmaXclbinParameter xclbin_nparam[MAX_XLNX_DEVS];
  for (int dev_id = 0; dev_id < devices; dev_id++) {
    xclbin_nparam[dev_id].device_id = dev_id;
    xclbin_nparam[dev_id].xclbin_name = (char*)XLNX_XCLBIN_PATH;
  }

  // NOTE: no idea why we need to manually open the library for the
  // libxma2plugin to work correctly */
  void* xmahandle = dlopen("libxma2api.so", RTLD_NOW | RTLD_GLOBAL);
  if (xmahandle == NULL) {
    return initialize_result_error(env, "failed to preload libxma2api");
  }

  if (xma_initialize(xclbin_nparam, devices) != 0) {
    return initialize_result_error(env, "failed to initialize xma");
  }

  return initialize_result_ok(env);
}
