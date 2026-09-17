#include "include/wave_audio/wave_audio_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "wave_audio_plugin.h"

void WaveAudioPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  wave_audio::WaveAudioPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}