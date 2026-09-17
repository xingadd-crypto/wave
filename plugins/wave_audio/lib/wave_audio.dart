import 'package:flutter/services.dart';

/// Minimal low-latency PCM16 (configurable rate/channels) audio I/O backed by
/// a Windows WASAPI plugin (wave_audio). Used by the voice-call feature on the
/// Windows desktop target and by the ultrasonic transfer flow; Android keeps
/// using flutter_sound.
class WaveAudio {
  WaveAudio._();

  static const MethodChannel _method = MethodChannel('wave_audio');
  static const EventChannel _events = EventChannel('wave_audio/events');

  /// Captured microphone PCM16 (little-endian) samples.
  static Stream<Uint8List> get captureEvents =>
      _events.receiveBroadcastStream().map((e) => e as Uint8List);

  /// Begins microphone capture at [sampleRate]/[numChannels]. Events flow on
  /// [captureEvents]. Defaults match the voice-call path (8 kHz mono).
  static Future<void> startCapture(
      {int sampleRate = 8000, int numChannels = 1}) async {
    await _method.invokeMethod<void>('startCapture', <String, dynamic>{
      'sampleRate': sampleRate,
      'numChannels': numChannels,
    });
  }

  static Future<void> stopCapture() async {
    await _method.invokeMethod<void>('stopCapture');
  }

  /// Starts speaker playback. PCM16 (little-endian) chunks fed via [play].
  static Future<void> startPlayback(int sampleRate, int numChannels) async {
    await _method.invokeMethod<void>('startPlayback', <String, dynamic>{
      'sampleRate': sampleRate,
      'numChannels': numChannels,
    });
  }

  /// Feeds next PCM16 (little-endian) chunk to the speaker.
  static Future<void> play(Uint8List pcm) async {
    await _method.invokeMethod<void>('play', pcm);
  }

  /// Fire-and-forget variant of [play].
  static void playAsync(Uint8List pcm) {
    _method.invokeMethod<void>('play', pcm);
  }

  static Future<void> stopPlayback() async {
    await _method.invokeMethod<void>('stopPlayback');
  }
}