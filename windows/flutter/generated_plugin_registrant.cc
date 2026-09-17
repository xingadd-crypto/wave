//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <flutter_secure_storage_windows/flutter_secure_storage_windows_plugin.h>
#include <flutter_sound/flutter_sound_plugin_c_api.h>
#include <gal/gal_plugin_c_api.h>
#include <ggwave_native/ggwave_native_plugin_c_api.h>
#include <permission_handler_windows/permission_handler_windows_plugin.h>
#include <wave_audio/wave_audio_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FlutterSecureStorageWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterSecureStorageWindowsPlugin"));
  FlutterSoundPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterSoundPluginCApi"));
  GalPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("GalPluginCApi"));
  GgwaveNativePluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("GgwaveNativePluginCApi"));
  PermissionHandlerWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PermissionHandlerWindowsPlugin"));
  WaveAudioPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("WaveAudioPluginCApi"));
}
