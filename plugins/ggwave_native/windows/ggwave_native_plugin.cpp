#include "ggwave_native_plugin.h"

#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

#include "ggwave_util.h"

namespace ggwave_native {

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;

const std::string kChannelName = "ggwave_native";
}  // namespace

GgwaveNativePlugin::GgwaveNativePlugin() {}

GgwaveNativePlugin::~GgwaveNativePlugin() {}

void GgwaveNativePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<GgwaveNativePlugin>();
  GgwaveNativePlugin* raw = plugin.get();

  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [raw](const auto& call, auto result) {
        raw->HandleMethodCall(call, std::move(result));
      });
  raw->channel_ = std::move(channel);

  registrar->AddPlugin(std::move(plugin));
}

void GgwaveNativePlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "encode") {
    const auto* args = std::get_if<EncodableMap>(method_call.arguments());
    if (args == nullptr) {
      result->Error("bad_argument", "encode expects a map argument");
      return;
    }
    std::string payload;
    bool audible = false;
    for (const auto& [k, v] : *args) {
      const auto* key = std::get_if<std::string>(&k);
      if (key == nullptr) continue;
      if (*key == "payload") {
        if (const auto* s = std::get_if<std::string>(&v)) payload = *s;
      } else if (*key == "audible") {
        if (const auto* b = std::get_if<bool>(&v)) audible = *b;
      }
    }
    if (payload.empty()) {
      result->Error("bad_argument", "encode expects a non-empty payload");
      return;
    }
    auto wf = ggw::Encode(payload, audible ? ggw::kProtoAudible
                                           : ggw::kProtoUltrasonic);
    if (wf.empty()) {
      // Retry with the alternate protocol for robustness.
      wf = ggw::Encode(payload, audible ? ggw::kProtoUltrasonic
                                        : ggw::kProtoAudible);
    }
    if (wf.empty()) {
      result->Error("encode_failed",
                    "ggwave could not encode payload (too long?)");
      return;
    }
    result->Success(EncodableValue(std::vector<uint8_t>(wf)));
  } else if (method == "decode") {
    const auto* args = std::get_if<EncodableMap>(method_call.arguments());
    if (args == nullptr) {
      result->Error("bad_argument", "decode expects a map argument");
      return;
    }
    std::vector<uint8_t> pcm;
    for (const auto& [k, v] : *args) {
      const auto* key = std::get_if<std::string>(&k);
      if (key == nullptr) continue;
      if (*key == "pcm") {
        if (const auto* bytes =
                std::get_if<std::vector<uint8_t>>(&v)) {
          pcm = *bytes;
        } else if (const auto* floats =
                       std::get_if<std::vector<double>>(&v)) {
          pcm.reserve(floats->size());
          for (double d : *floats) pcm.push_back(static_cast<uint8_t>(d));
        }
      }
    }
    if (pcm.empty()) {
      result->Success();
      return;
    }
    const std::string payload = ggw::Decode(pcm.data(), pcm.size());
    if (payload.empty()) {
      result->Success();
    } else {
      result->Success(EncodableValue(payload));
    }
  } else {
    result->NotImplemented();
  }
}

}  // namespace ggwave_native