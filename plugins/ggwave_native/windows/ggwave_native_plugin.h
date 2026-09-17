#ifndef FLUTTER_PLUGIN_GGWAVE_NATIVE_PLUGIN_H_
#define FLUTTER_PLUGIN_GGWAVE_NATIVE_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

namespace ggwave_native {

class GgwaveNativePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  GgwaveNativePlugin();
  virtual ~GgwaveNativePlugin();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace ggwave_native

#endif  // FLUTTER_PLUGIN_GGWAVE_NATIVE_PLUGIN_H_