import 'package:flutter/services.dart';

/// ggwave data-over-sound DSP binding.
///
/// Pure encoding/decoding only — audio I/O (speaker/microphone) stays in the
/// app so this plugin is platform-neutral. All PCM is 16-bit little-endian
/// mono at [sampleRate] (48 kHz), the operating rate of the ultrasonic flow.
class GgwaveNative {
  GgwaveNative._();

  static const MethodChannel _method = MethodChannel('ggwave_native');

  /// Operating sample rate used across the app for ultrasonic transfers.
  static const int sampleRate = 48000;

  /// Encodes [payload] into PCM16 LE mono audio at [sampleRate].
  ///
  /// [audible] selects the ultrasonic protocol (default, inaudible to most
  /// humans) or an audible-tone variant for speakers that cannot reproduce
  /// high frequencies. Returns null when encoding fails (e.g. payload too
  /// long).
  static Future<Uint8List?> encode(String payload, {bool audible = false}) async {
    final bytes = await _method.invokeMethod<Uint8List>('encode', <String, dynamic>{
      'payload': payload,
      'audible': audible,
    });
    return bytes;
  }

  /// Decodes [pcm] (PCM16 LE mono at [sampleRate]) into the payload string,
  /// or null when no valid payload is detected.
  static Future<String?> decode(Uint8List pcm) async {
    final result =
        await _method.invokeMethod<String>('decode', <String, dynamic>{'pcm': pcm});
    return result;
  }
}