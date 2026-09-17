import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_sound/public/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wave_audio/wave_audio.dart';

import 'g711.dart';

/// Voice-message audio I/O, independent from the realtime call path.
///
/// Mirrors the CLI's `VoiceRecorder` / `play_voice_buffer`: records raw PCM16
/// (8 kHz, mono) for a stretch, then encodes it to G.711 μ-law bytes for
/// transmission / storage, and plays μ-law bytes back through the speaker.
/// This keeps voice messages fully compatible with the Rust CLI (same μ-law
/// 8 kHz mono format used by `protocol::VoiceMessage`).
///
/// Windows uses the [WaveAudio] WASAPI plugin (flutter_sound's Windows
/// plugin is non-functional); Android/iOS use flutter_sound.
class VoiceMessageIO {
  static const int sampleRate = 8000;
  static const int _bufferSize = 8192;

  static bool get _useWaveAudio => Platform.isWindows;

  // flutter_sound state (mobile).
  FlutterSoundRecorder? _recorder;
  FlutterSoundPlayer? _player;
  StreamController<List<Int16List>>? _streamInt16Controller;
  StreamSubscription<List<Int16List>>? _streamInt16Subscription;

  // wave_audio state (Windows).
  StreamSubscription<Uint8List>? _waCaptureSubscription;

  // Accumulated recorded PCM16 samples as raw little-endian bytes (mono).
  // Byte-based accumulation avoids per-sample boxed ints and a final copy.
  final BytesBuilder _pcmBuf = BytesBuilder(copy: false);

  int _durationMs(int samples) => (samples * 1000 ~/ sampleRate);

  /// Converts a PCM16 [Int16List] to raw little-endian bytes for buffering.
  Uint8List _int16ToBytes(Int16List pcm) {
    final out = Uint8List(pcm.length << 1);
    if (pcm.isNotEmpty) {
      final view = Int16List.view(out.buffer);
      view.setAll(0, pcm);
    }
    return out;
  }

  /// Finalizes a capture: returns the μ-law bytes plus the duration in ms.
  ({Uint8List mulaw, int durationMs})? _finishCapture() {
    final bytes = _pcmBuf.takeBytes();
    if (bytes.length < 2) return null;
    final pcm = Int16List.view(bytes.buffer, 0, bytes.lengthInBytes ~/ 2);
    return (mulaw: mulawEncodeFrame(agcBoost(pcm)), durationMs: _durationMs(pcm.length));
  }

  /// Starts capturing; call the returned stop function to finish and get back
  /// the μ-law bytes plus the duration in milliseconds.
  Future<({Uint8List mulaw, int durationMs})?> Function()
      _buildStopCollector() {
    if (_useWaveAudio) {
      _waCaptureSubscription = WaveAudio.captureEvents.listen((bytes) {
        if (bytes.length >= 2) {
          _pcmBuf.add(Uint8List.sublistView(bytes, 0, bytes.length & ~1));
        }
      });
      return () async {
        await _waCaptureSubscription?.cancel();
        _waCaptureSubscription = null;
        await WaveAudio.stopCapture();
        return _finishCapture();
      };
    }
    // Mobile: the controller/subscription are created in start() before
    // startRecorder; here we just build the stop closure over them.
    return () async {
      _streamInt16Subscription?.cancel();
      _streamInt16Subscription = null;
      try {
        await _streamInt16Controller?.close();
      } catch (_) {}
      _streamInt16Controller = null;
      // Encourage a hard release even when stopRecorder throws, so the mic is
      // never left captured after a voice message is done.
      if (_recorder != null) {
        final recorder = _recorder!;
        _recorder = null;
        try {
          await recorder.stopRecorder();
        } catch (_) {}
        try {
          await recorder.closeRecorder();
        } catch (_) {}
      }
      return _finishCapture();
    };
  }

  /// Opens the microphone and begins recording. Returns a stop function that,
  /// when awaited, returns the recorded μ-law bytes + duration (or null if
  /// nothing was captured). Recording can be abandoned by awaiting stop and
  /// ignoring its result.
  Future<Future<({Uint8List mulaw, int durationMs})?> Function()?> start()
      async {
    if (_useWaveAudio) {
      try {
        await WaveAudio.startCapture();
        return _buildStopCollector();
      } catch (e) {
        return null;
      }
    }
    _recorder = FlutterSoundRecorder();
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _recorder = null;
      return null;
    }
    _streamInt16Controller = StreamController<List<Int16List>>();
    _streamInt16Subscription = _streamInt16Controller!.stream.listen((chunks) {
      for (final chunk in chunks) {
        _pcmBuf.add(_int16ToBytes(chunk));
      }
    });
    try {
      await _recorder!.openRecorder();
      await _recorder!.startRecorder(
        codec: Codec.pcm16,
        toStreamInt16: _streamInt16Controller!.sink,
        sampleRate: sampleRate,
        numChannels: 1,
        audioSource: AudioSource.microphone,
      );
      return _buildStopCollector();
    } catch (e) {
      final ctrl = _streamInt16Controller;
      _streamInt16Controller = null;
      _streamInt16Subscription?.cancel();
      _streamInt16Subscription = null;
      await ctrl?.close();
      _pcmBuf.clear();
      await _releaseRecorder();
      return null;
    }
  }

  /// Plays a complete μ-law voice message buffer (non-blocking).
  Future<void> play(Uint8List mulaw) async {
    final pcm = mulawDecodeFrame(mulaw);
    if (pcm.isEmpty) return;
    if (_useWaveAudio) {
      try {
        await WaveAudio.startPlayback(sampleRate, 1);
        WaveAudio.playAsync(_int16ToBytes(pcm));
        return;
      } catch (e) {
        return;
      }
    }
    final player = _player ??= FlutterSoundPlayer();
    try {
      await player.openPlayer();
      await player.startPlayerFromStream(
        codec: Codec.pcm16,
        interleaved: true,
        numChannels: 1,
        sampleRate: sampleRate,
        bufferSize: _bufferSize,
      );
      final sink = player.uint8ListSink;
      if (sink != null) {
        sink.add(_int16ToBytes(pcm));
      }
    } catch (e) {
      // ignore playback errors
    }
  }

  /// Stops any in-progress playback started by [play]. Safe to call when
  /// nothing is playing.
  Future<void> stopPlayback() async {
    if (_useWaveAudio) {
      try {
        await WaveAudio.stopPlayback();
      } catch (_) {}
      return;
    }
    final player = _player;
    if (player != null) {
      try {
        await player.stopPlayer();
      } catch (_) {}
    }
  }

  /// Releases microphone/player resources.
  Future<void> dispose() async {
    if (_useWaveAudio) {
      await _waCaptureSubscription?.cancel();
      _waCaptureSubscription = null;
      await WaveAudio.stopCapture();
      await WaveAudio.stopPlayback();
    } else {
      _streamInt16Subscription?.cancel();
      _streamInt16Subscription = null;
      await _streamInt16Controller?.close();
      _streamInt16Controller = null;
      final player = _player;
      _player = null;
      if (player != null) {
        try {
          await player.stopPlayer();
        } catch (_) {}
        try {
          await player.closePlayer();
        } catch (_) {}
      }
      await _releaseRecorder();
      _pcmBuf.clear();
    }
  }

  Future<void> _releaseRecorder() async {
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      try {
        await recorder.stopRecorder();
      } catch (_) {}
      try {
        await recorder.closeRecorder();
      } catch (_) {}
    }
  }
}
