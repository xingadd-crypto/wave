#include "include/ggwave_native/ggwave_native_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "ggwave_native_plugin.h"

void GgwaveNativePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  ggwave_native::GgwaveNativePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}