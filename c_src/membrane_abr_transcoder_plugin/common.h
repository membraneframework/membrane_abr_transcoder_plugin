#pragma once

struct EncodedFrame {
  int pts;
  int dts;
  uint32_t size;
  uint8_t* data;
};
