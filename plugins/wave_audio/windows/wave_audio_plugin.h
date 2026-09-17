#ifndef FLUTTER_PLUGIN_WAVE_AUDIO_PLUGIN_H_
#define FLUTTER_PLUGIN_WAVE_AUDIO_PLUGIN_H_

#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <Audioclient.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <atomic>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

namespace wave_audio {

using Microsoft::WRL::ComPtr;

class WaveAudioPlugin;

// Owns the EventChannel stream handler contract. Kept alive by the event
// channel itself; forwards listen/cancel to the owning plugin.
class WaveAudioCaptureHandler
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  explicit WaveAudioCaptureHandler(WaveAudioPlugin* plugin) : plugin_(plugin) {}

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(const flutter::EncodableValue* arguments,
                   std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                       events) override;

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* arguments) override;

 private:
  WaveAudioPlugin* plugin_;
};

class WaveAudioPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  WaveAudioPlugin();
  virtual ~WaveAudioPlugin();

  void StoreEventSink(
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
    event_sink_ = std::move(events);
  }

  void ClearEventSink() { event_sink_.reset(); }

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void StartCapture(int sample_rate, int channels);
  void StopCapture();
  void StartPlayback(int sample_rate, int channels);
  void PlayBytes(const flutter::EncodableValue* value);
  void StopPlayback();

  void CaptureLoop();
  void RenderLoop();

  static constexpr int kDefaultSampleRate = 8000;
  static constexpr int kDefaultChannels = 1;
  static constexpr int kBytesPerSample = 2;

  // Enforced ceiling for the pending-playback queue (~250 ms of 8 kHz mono
  // PCM16 = 4 KiB). Keeps listener latency bounded during network bursts
  // instead of letting the queue grow to many seconds of stale audio.
  static constexpr size_t kMaxRenderQueueBytes = 4 * 1024;

  // WASAPI device buffer duration in 100ns units (100 ms). Small enough for a
  // snappy, low-latency call; large enough to avoid over/underrun jitter.
  static constexpr REFERENCE_TIME kDeviceBufferDuration = 1000000;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  std::atomic<bool> capture_started_{false};
  std::thread capture_thread_;
  int capture_sample_rate_ = kDefaultSampleRate;
  int capture_channels_ = kDefaultChannels;

  std::atomic<bool> render_started_{false};
  std::thread render_thread_;
  HANDLE render_event_ = nullptr;

  ComPtr<IAudioClient> capture_client_;
  ComPtr<IAudioCaptureClient> capture_;

  ComPtr<IAudioClient> render_client_;
  ComPtr<IAudioRenderClient> render_;

  std::mutex queue_mutex_;
  std::deque<std::vector<uint8_t>> pcm_queue_;
  size_t queue_bytes_ = 0;
};

}  // namespace wave_audio

#endif  // FLUTTER_PLUGIN_WAVE_AUDIO_PLUGIN_H_