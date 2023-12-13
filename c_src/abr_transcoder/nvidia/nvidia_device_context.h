#pragma once

#include <vector>

extern "C" {
#include <libavutil/buffer.h>
#include <libavutil/hwcontext.h>
}


class NvidiaDeviceContext {
public:
  NvidiaDeviceContext(unsigned int outputs);
  ~NvidiaDeviceContext();

  bool Initialize();

  AVBufferRef* GetDeviceContext() const { return device_context; }

  void PutFrameContext(unsigned int idx, AVBufferRef* frame_context);

  AVBufferRef* GetFramesContext(unsigned int idx) const {
    if (idx >= frame_contexts.size()) {
      return nullptr;
    }

    return frame_contexts[idx];
  }

private:
  AVBufferRef* device_context;
  std::vector<AVBufferRef*> frame_contexts;
};
