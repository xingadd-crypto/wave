#include "wave_audio_plugin.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#include <algorithm>
#include <cstdio>
#include <functional>
#include <string>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

namespace {

// Guards that an interface was successfully acquired before use.
bool Succeeded(HRESULT hr) { return SUCCEEDED(hr); }

std::string Hr(HRESULT hr) {
  char buf[32] = {0};
  snprintf(buf, sizeof(buf), "0x%08lX", static_cast<unsigned long>(hr));
  return std::string(buf);
}

// Appends a diagnostic line to "wave_audio.log" next to the executable.
void WaveLog(const std::string& msg) {
  char path[MAX_PATH] = {0};
  GetModuleFileNameA(nullptr, path, MAX_PATH);
  std::string dir(path);
  auto pos = dir.find_last_of('\\');
  if (pos != std::string::npos) {
    dir = dir.substr(0, pos);
  }
  dir += "\\wave_audio.log";
  FILE* f = nullptr;
  if (fopen_s(&f, dir.c_str(), "a") != 0 || f == nullptr) {
    return;
  }
  fprintf(f, "%s\n", msg.c_str());
  fclose(f);
}

WAVEFORMATEX MakePcmFormat(int sample_rate, int channels) {
  WAVEFORMATEX fmt = {0};
  fmt.wFormatTag = WAVE_FORMAT_PCM;
  fmt.nChannels = static_cast<WORD>(channels);
  fmt.nSamplesPerSec = static_cast<DWORD>(sample_rate);
  fmt.wBitsPerSample = 16;
  fmt.nBlockAlign = static_cast<WORD>(channels * 2);
  fmt.nAvgBytesPerSec = sample_rate * fmt.nBlockAlign;
  fmt.cbSize = 0;
  return fmt;
}

}  // namespace

namespace wave_audio {

using Microsoft::WRL::ComPtr;

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;

int AsInt(const EncodableValue& value) {
  if (const auto* i = std::get_if<int32_t>(&value)) {
    return *i;
  }
  if (const auto* i = std::get_if<int64_t>(&value)) {
    return static_cast<int>(*i);
  }
  return 0;
}

int GetArgInt(const flutter::EncodableValue* args, const char* key,
              int fallback) {
  if (args == nullptr) {
    return fallback;
  }
  const auto* map = std::get_if<flutter::EncodableMap>(args);
  if (map == nullptr) {
    return fallback;
  }
  auto it = map->find(EncodableValue(key));
  if (it == map->end()) {
    return fallback;
  }
  return AsInt(it->second);
}
}  // namespace

std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>
WaveAudioCaptureHandler::OnListenInternal(
    const EncodableValue* arguments,
    std::unique_ptr<flutter::EventSink<EncodableValue>>&& events) {
  plugin_->StoreEventSink(std::move(events));
  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>
WaveAudioCaptureHandler::OnCancelInternal(const EncodableValue* arguments) {
  plugin_->ClearEventSink();
  return nullptr;
}

WaveAudioPlugin::WaveAudioPlugin() {}

WaveAudioPlugin::~WaveAudioPlugin() {
  StopCapture();
  StopPlayback();
}

void WaveAudioPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<WaveAudioPlugin>();
  auto* raw = plugin.get();
  auto* messenger = registrar->messenger();

  // Method channel for commands.
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "wave_audio",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [raw](const auto& call, auto result) {
        raw->HandleMethodCall(call, std::move(result));
      });
  raw->channel_ = std::move(channel);

  // Event channel for captured PCM16 frames. The handler is owned by the
  // channel (which keeps it alive via a shared pointer); it forwards to the
  // plugin object (owned by the registrar).
  auto event_channel = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, "wave_audio/events",
      &flutter::StandardMethodCodec::GetInstance());
  auto handler = std::make_unique<WaveAudioCaptureHandler>(raw);
  event_channel->SetStreamHandler(std::move(handler));
  raw->event_channel_ = std::move(event_channel);

  registrar->AddPlugin(std::move(plugin));
}

void WaveAudioPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = method_call.method_name();
  if (method == "startCapture") {
    int sample_rate =
        GetArgInt(method_call.arguments(), "sampleRate", kDefaultSampleRate);
    int channels =
        GetArgInt(method_call.arguments(), "numChannels", kDefaultChannels);
    if (sample_rate <= 0) {
      sample_rate = kDefaultSampleRate;
    }
    if (channels <= 0) {
      channels = kDefaultChannels;
    }
    StartCapture(sample_rate, channels);
    result->Success();
  } else if (method == "stopCapture") {
    StopCapture();
    result->Success();
  } else if (method == "startPlayback") {
    int sample_rate =
        GetArgInt(method_call.arguments(), "sampleRate", kDefaultSampleRate);
    int channels =
        GetArgInt(method_call.arguments(), "numChannels", kDefaultChannels);
    if (sample_rate <= 0) {
      sample_rate = kDefaultSampleRate;
    }
    if (channels <= 0) {
      channels = kDefaultChannels;
    }
    StartPlayback(sample_rate, channels);
    result->Success();
  } else if (method == "play") {
    PlayBytes(method_call.arguments());
    result->Success();
  } else if (method == "stopPlayback") {
    StopPlayback();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

// ---------------------------------------------------------------------------
// Capture (microphone)
// ---------------------------------------------------------------------------

void WaveAudioPlugin::StartCapture(int sample_rate, int channels) {
  if (capture_started_.exchange(true)) {
    return;
  }
  capture_sample_rate_ = sample_rate;
  capture_channels_ = channels;
  try {
    capture_thread_ = std::thread(&WaveAudioPlugin::CaptureLoop, this);
  } catch (...) {
    capture_started_ = false;
  }
}

void WaveAudioPlugin::StopCapture() {
  capture_started_ = false;
  if (capture_thread_.joinable()) {
    capture_thread_.join();
  }
}

void WaveAudioPlugin::CaptureLoop() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);

  HRESULT hr;
  ComPtr<IMMDeviceEnumerator> enumerator;
  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        IID_PPV_ARGS(&enumerator));
  WaveLog("capture: CoCreate hr=" + Hr(hr));
  if (Succeeded(hr)) {
    ComPtr<IMMDevice> device;
    hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
    WaveLog("capture: GetEndpoint hr=" + Hr(hr));
    if (Succeeded(hr)) {
      hr = device->Activate(
          __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
          reinterpret_cast<void**>(capture_client_.GetAddressOf()));
      WaveLog("capture: Activate hr=" + Hr(hr));
    }
  }

  if (capture_client_ != nullptr) {
    WAVEFORMATEX fmt =
        MakePcmFormat(capture_sample_rate_, capture_channels_);
    hr = capture_client_->Initialize(
        AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
        kDeviceBufferDuration, 0, &fmt, nullptr);
    WaveLog("capture: Initialize hr=" + Hr(hr));
    if (Succeeded(hr)) {
      hr = capture_client_->GetService(IID_PPV_ARGS(&capture_));
      WaveLog("capture: GetService hr=" + Hr(hr));
      if (Succeeded(hr)) {
        hr = capture_client_->Start();
        WaveLog("capture: Start hr=" + Hr(hr));
        if (!Succeeded(hr)) {
          capture_.Reset();
        }
      }
    } else {
      capture_client_.Reset();
    }
  }

  UINT32 packet_size = 0;
  int packet_count = 0;
  while (capture_started_) {
    if (capture_ != nullptr) {
      HRESULT status = capture_->GetNextPacketSize(&packet_size);
      while (Succeeded(status) && packet_size > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        status = capture_->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (Succeeded(status) && frames > 0) {
          if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) == 0) {
            packet_count++;
            if (packet_count <= 2 || packet_count % 100 == 0) {
              WaveLog("capture: pkt #" + std::to_string(packet_count) +
                      " frames=" + std::to_string(frames));
            }
            std::vector<uint8_t> chunk(
                data, data + frames * capture_channels_ * kBytesPerSample);
            auto* sink = event_sink_.get();
            if (sink != nullptr) {
              sink->Success(EncodableValue(std::move(chunk)));
            }
          }
          capture_->ReleaseBuffer(frames);
          status = capture_->GetNextPacketSize(&packet_size);
        }
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }

  if (capture_ != nullptr) {
    capture_client_->Stop();
    capture_.Reset();
  }
  capture_client_.Reset();
  CoUninitialize();
}

// ---------------------------------------------------------------------------
// Playback (speaker)
// ---------------------------------------------------------------------------

void WaveAudioPlugin::StartPlayback(int sample_rate, int channels) {
  if (render_started_.exchange(true)) {
    return;
  }

  HANDLE event = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  if (event == nullptr) {
    render_started_ = false;
    return;
  }
  render_event_ = event;

  HRESULT hr;
  ComPtr<IMMDeviceEnumerator> enumerator;
  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        IID_PPV_ARGS(&enumerator));
  WaveLog("playback: CoCreate hr=" + Hr(hr));
  if (Succeeded(hr)) {
    ComPtr<IMMDevice> device;
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    WaveLog("playback: GetEndpoint hr=" + Hr(hr));
    if (Succeeded(hr)) {
      hr = device->Activate(
          __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
          reinterpret_cast<void**>(render_client_.GetAddressOf()));
      WaveLog("playback: Activate hr=" + Hr(hr));
    }
  }

  if (render_client_ != nullptr) {
    WAVEFORMATEX fmt = MakePcmFormat(sample_rate, channels);
    hr = render_client_->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
        kDeviceBufferDuration, 0, &fmt, nullptr);
    WaveLog("playback: Initialize hr=" + Hr(hr));
    if (Succeeded(hr)) {
      hr = render_client_->SetEventHandle(event);
      WaveLog("playback: SetEventHandle hr=" + Hr(hr));
      if (Succeeded(hr)) {
        hr = render_client_->GetService(IID_PPV_ARGS(&render_));
        WaveLog("playback: GetService hr=" + Hr(hr));
        if (Succeeded(hr)) {
          hr = render_client_->Start();
          WaveLog("playback: Start hr=" + Hr(hr));
          if (!Succeeded(hr)) {
            render_.Reset();
          }
        }
      }
    } else {
      render_client_.Reset();
    }
  }

  try {
    render_thread_ = std::thread(&WaveAudioPlugin::RenderLoop, this);
  } catch (...) {
    StopPlayback();
  }
}

void WaveAudioPlugin::StopPlayback() {
  render_started_ = false;
  if (render_thread_.joinable()) {
    render_thread_.join();
  }
  if (render_event_ != nullptr) {
    CloseHandle(render_event_);
    render_event_ = nullptr;
  }
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    pcm_queue_.clear();
    queue_bytes_ = 0;
  }
  render_.Reset();
  render_client_.Reset();
}

void WaveAudioPlugin::PlayBytes(const EncodableValue* value) {
  if (!render_started_ || value == nullptr) {
    return;
  }
  if (!std::holds_alternative<std::vector<uint8_t>>(*value)) {
    WaveLog("play: non-bytes arg");
    return;
  }
  const auto& bytes = std::get<std::vector<uint8_t>>(*value);
  if (bytes.empty()) {
    return;
  }
  static long long play_total = 0;
  play_total++;
  if (play_total <= 2 || play_total % 200 == 0) {
    WaveLog("play: #" + std::to_string(play_total) +
            " bytes=" + std::to_string(bytes.size()));
  }
  std::lock_guard<std::mutex> lock(queue_mutex_);
  // Bound the pending queue by audio duration (see kMaxRenderQueueBytes), so a
  // burst cannot build up seconds of stale latency; drop the oldest data when
  // the ceiling is exceeded (RenderLoop decrements queue_bytes_ as it
  // consumes, including partial-entry takes).
  queue_bytes_ += bytes.size();
  while (queue_bytes_ > kMaxRenderQueueBytes && !pcm_queue_.empty()) {
    queue_bytes_ -= pcm_queue_.front().size();
    pcm_queue_.pop_front();
  }
  pcm_queue_.push_back(bytes);
}

void WaveAudioPlugin::RenderLoop() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);

  if (render_ != nullptr) {
    HANDLE event = render_event_;
    uint64_t rendered_bytes = 0;
    long long iter = 0;
    while (render_started_) {
      WaitForSingleObject(event, 100);
      UINT32 padding = 0;
      UINT32 buffer_frames = 0;
      if (render_client_->GetCurrentPadding(&padding) != S_OK ||
          render_client_->GetBufferSize(&buffer_frames) != S_OK) {
        WaveLog("render: padding/buffersize error");
        break;
      }
      if (buffer_frames <= padding) {
        continue;
      }
      UINT32 frames_ready = buffer_frames - padding;
      BYTE* data = nullptr;
      if (render_->GetBuffer(frames_ready, &data) != S_OK) {
        WaveLog("render: GetBuffer error");
        break;
      }
      size_t bytes_to_write = frames_ready * kBytesPerSample;
      size_t copied = 0;
      {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        while (copied < bytes_to_write && !pcm_queue_.empty()) {
          auto& head = pcm_queue_.front();
          size_t take = std::min(head.size(), bytes_to_write - copied);
          queue_bytes_ -= take;
          std::memcpy(data + copied, head.data(), take);
          copied += take;
          if (take == head.size()) {
            pcm_queue_.pop_front();
          } else {
            head.erase(head.begin(), head.begin() + take);
          }
        }
      }
      if (copied < bytes_to_write) {
        std::memset(data + copied, 0, bytes_to_write - copied);
      }
      rendered_bytes += bytes_to_write;
      iter++;
      if (iter <= 2 || iter % 100 == 0) {
        WaveLog("render: iter #" + std::to_string(iter) + " frames=" +
                std::to_string(frames_ready) + " total_bytes=" +
                std::to_string(rendered_bytes));
      }
      render_->ReleaseBuffer(frames_ready, 0);
    }
    render_client_->Stop();
    render_.Reset();
  } else {
    WaveLog("render: render client not available; loop skipped");
  }

  CoUninitialize();
}

}  // namespace wave_audio