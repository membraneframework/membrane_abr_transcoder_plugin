
#include "nvidia_device_context.h"

bool NvidiaDeviceContext::Initialize() {
  int ret = av_hwdevice_ctx_create(
      &device_context, AV_HWDEVICE_TYPE_CUDA, "/dev/dri/render128", NULL, 0);

  if (ret < 0) {
    av_buffer_unref(&device_context);
    device_context = nullptr;
    return false;
  }

  return true;
}

NvidiaDeviceContext::~NvidiaDeviceContext() {
  if (device_context == nullptr) {
    return;
  }

  av_buffer_unref(&device_context);
}
