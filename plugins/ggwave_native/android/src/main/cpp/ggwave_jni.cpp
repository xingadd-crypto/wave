#include <jni.h>

#include <cstdint>
#include <string>
#include <vector>

#include "ggwave_util.h"

namespace {

int OtherProtocol(int p) {
  return p == ggw::kProtoUltrasonic ? ggw::kProtoAudible : ggw::kProtoUltrasonic;
}

}  // namespace

extern "C" {

JNIEXPORT jbyteArray JNICALL
Java_com_wave_ggwave_GgwaveNativePlugin_nativeEncode(JNIEnv* env, jclass,
                                                     jstring jPayload,
                                                     jboolean audible) {
  const char* utf = env->GetStringUTFChars(jPayload, nullptr);
  if (utf == nullptr) return nullptr;
  std::string payload(utf);
  env->ReleaseStringUTFChars(jPayload, utf);

  int protocol = audible ? ggw::kProtoAudible : ggw::kProtoUltrasonic;
  auto wf = ggw::Encode(payload, protocol);
  if (wf.empty()) {
    wf = ggw::Encode(payload, OtherProtocol(protocol));
  }
  if (wf.empty()) return nullptr;

  jbyteArray out = env->NewByteArray(static_cast<jsize>(wf.size()));
  if (out == nullptr) return nullptr;
  env->SetByteArrayRegion(out, 0, static_cast<jsize>(wf.size()),
                          reinterpret_cast<const jbyte*>(wf.data()));
  return out;
}

JNIEXPORT jstring JNICALL
Java_com_wave_ggwave_GgwaveNativePlugin_nativeDecode(JNIEnv* env, jclass,
                                                     jbyteArray jPcm) {
  jsize len = env->GetArrayLength(jPcm);
  if (len <= 0) return nullptr;
  std::vector<jbyte> buf(static_cast<size_t>(len));
  env->GetByteArrayRegion(jPcm, 0, len, buf.data());

  std::string result = ggw::Decode(reinterpret_cast<const uint8_t*>(buf.data()),
                                   static_cast<size_t>(len));
  if (result.empty()) return nullptr;
  return env->NewStringUTF(result.c_str());
}

}  // extern "C"