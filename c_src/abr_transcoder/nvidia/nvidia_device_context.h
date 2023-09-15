#pragma once

extern "C" {
#include <libavutil/buffer.h>
#include <libavutil/hwcontext.h>
}


class NvidiaDeviceContext {
public:
  NvidiaDeviceContext() = default;
  ~NvidiaDeviceContext();

  bool Initialize();

  AVBufferRef* GetDeviceContext() const { return device_context; }

private:
  AVBufferRef* device_context;
};
