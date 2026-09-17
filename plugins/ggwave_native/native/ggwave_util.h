#ifndef GGWAVE_NATIVE_UTIL_H_
#define GGWAVE_NATIVE_UTIL_H_

#include "ggwave/ggwave.h"

#include <cstdint>
#include <string>
#include <vector>

namespace ggw {

constexpr int kSampleRate = 48000;
constexpr int kProtoUltrasonic = GGWAVE_PROTOCOL_ULTRASOUND_FASTEST;
constexpr int kProtoAudible = GGWAVE_PROTOCOL_AUDIBLE_FASTEST;
constexpr int kEncodeVolume = 35;

inline ggwave_Parameters MakeParams(int mode) {
  ggwave_Parameters p = ggwave_getDefaultParameters();
  p.payloadLength = 0;  // variable length (with markers)
  p.sampleRate = kSampleRate;
  p.sampleRateInp = kSampleRate;
  p.sampleRateOut = kSampleRate;
  p.samplesPerFrame = 1024;
  p.sampleFormatInp = GGWAVE_SAMPLE_FORMAT_I16;
  p.sampleFormatOut = GGWAVE_SAMPLE_FORMAT_I16;
  p.operatingMode = mode;
  return p;
}

inline std::vector<uint8_t> Encode(const std::string& payload, int protocol,
                                   int volume = kEncodeVolume) {
  ggwave_setLogFile(nullptr);
  ggwave_Instance inst = ggwave_init(MakeParams(GGWAVE_OPERATING_MODE_TX));
  if (inst < 0) return {};
  int n = ggwave_encode(inst, payload.data(), static_cast<int>(payload.size()),
                        static_cast<ggwave_ProtocolId>(protocol), volume, nullptr, 1);
  if (n <= 0) {
    ggwave_free(inst);
    return {};
  }
  std::vector<uint8_t> wf(static_cast<size_t>(n));
  n = ggwave_encode(inst, payload.data(), static_cast<int>(payload.size()),
                    static_cast<ggwave_ProtocolId>(protocol), volume, wf.data(), 0);
  if (n <= 0) {
    ggwave_free(inst);
    return {};
  }
  wf.resize(static_cast<size_t>(n));
  ggwave_free(inst);
  return wf;
}

inline std::string Decode(const uint8_t* pcm, size_t bytes) {
  ggwave_setLogFile(nullptr);
  ggwave_Instance inst = ggwave_init(MakeParams(GGWAVE_OPERATING_MODE_RX));
  if (inst < 0) return {};
  const int frame_bytes = 1024 * 2;  // samplesPerFrame * sizeof(int16)
  std::vector<uint8_t> payload(256);
  std::string result;
  size_t off = 0;
  while (off + frame_bytes <= bytes) {
    int ret = ggwave_ndecode(inst, pcm + off, frame_bytes, payload.data(),
                             static_cast<int>(payload.size()));
    if (ret > 0) {
      result.assign(reinterpret_cast<const char*>(payload.data()),
                    static_cast<size_t>(ret));
      break;
    }
    off += frame_bytes;
  }
  ggwave_free(inst);
  return result;
}

}  // namespace ggw

#endif  // GGWAVE_NATIVE_UTIL_H_