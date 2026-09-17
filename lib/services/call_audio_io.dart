import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:flutter_sound/public/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wave_audio/wave_audio.dart';

/// Audio-device-only I/O abstraction for the P2P voice-call feature.
///
/// On Windows desktop it is backed by the [WaveAudio] WASAPI plugin (the
/// flutter_sound Windows plugin ships non-functional, so calls there would
/// otherwise fail to open the audio session). On Android/iOS it keeps using
/// flutter_sound, which is fully implemented on those platforms.
///
/// The call layer receives raw PCM16 samples via [start]'s [onCapture]
/// callback and feeds decoded PCM16 samples to the speaker via [play].
class CallAudioIO {
  static bool get _useWaveAudio => Platform.isWindows;

  // flutter_sound state (mobile).
  FlutterSoundRecorder? _recorder;
  FlutterSoundPlayer? _player;

  StreamController<Int16List>? _captureController;
  StreamSubscription<Int16List>? _captureSubscription;

  // Intermediary controller matching the recorder's toStreamInt16
  // signature: List<Int16List> (one Int16List per channel). We use a
  // single mono channel, so each event carries a one-element list whose
  // sole Int16List holds the captured PCM samples.
  StreamController<List<Int16List>>? _streamInt16Controller;
  StreamSubscription<List<Int16List>>? _streamInt16Subscription;

  // wave_audio state (Windows).
  StreamSubscription<Uint8List>? _waCaptureSubscription;

  void Function(Int16List pcm)? _onCapture;
  bool _started = false;

  static const int _sampleRate = 8000;
  static const int _bufferSize = 8192;

  // Playback backlog budget in milliseconds. The sample counting exploits the
  // fact that 1 sample of 8 kHz mono audio plays back in 1/8000 s: feeding N
  // samples adds N * 1000 / 8000 ms of predicted playback time, while real
  // wall-clock time passing shrinks it. When the far end outpaces the speaker
  // by more than this budget, frames are shed instead of queuing without bound
  // (flutter_sound's uint8ListSink and wave_audio's playAsync both have
  // unbounded queues underneath).
  static const int _maxBacklogMs = 300;
  int _backlogMs = 0;
  int _lastPlayMs = 0;

  /// Opens the audio sessions (mic capture + speaker playback) and begins
  /// streaming raw PCM16 samples (8 kHz, mono) to [onCapture]. Playback
  /// accepts decoded PCM16 via [play].
  Future<void> start({required void Function(Int16List pcm) onCapture}) async {
    if (_started) {
      return;
    }
    _onCapture = onCapture;
    if (_useWaveAudio) {
      await _startWaveAudio();
    } else {
      await _startFlutterSound();
    }
  }

  /// Feeds the given PCM16 samples to the speaker. Non-blocking enqueue with a
  /// hard backlog bound: frames are dropped once delivery is more than
  /// [_maxBacklogMs] behind, so a flooded peer sheds audio instead of
  /// ballooning the playback queue's memory.
  void play(Int16List pcm) {
    if (!_started || pcm.isEmpty) {
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_lastPlayMs == 0) _lastPlayMs = nowMs;
    final elapsedMs = nowMs - _lastPlayMs;
    _lastPlayMs = nowMs;
    _backlogMs = max(0, _backlogMs - elapsedMs);

    final frameMs = (pcm.length * 1000) ~/ _sampleRate;
    if (_backlogMs + frameMs > _maxBacklogMs) {
      // Drop the frame; keep the accounting at half budget so bursts are still
      // shed but the channel can recover as backlog drains.
      _backlogMs = min(_backlogMs, _maxBacklogMs ~/ 2);
      return;
    }
    _backlogMs += frameMs;

    if (_useWaveAudio) {
      WaveAudio.playAsync(_int16ToBytes(pcm));
      return;
    }
    final player = _player;
    if (player == null) {
      return;
    }
    final sink = player.uint8ListSink;
    if (sink == null) {
      return;
    }
    sink.add(_int16ToBytes(pcm));
  }

  /// Stops recording and playback and closes the audio sessions. Idempotent.
  Future<void> stop() async {
    if (_useWaveAudio) {
      await _waCaptureSubscription?.cancel();
      _waCaptureSubscription = null;
      await WaveAudio.stopCapture();
      await WaveAudio.stopPlayback();
    } else {
      final player = _player;
      final recorder = _recorder;
      await _teardownStreaming();
      if (player != null) {
        await player.stopPlayer();
      }
      if (recorder != null) {
        await recorder.stopRecorder();
      }
    }
    _started = false;
    _backlogMs = 0;
    _lastPlayMs = 0;
  }

  /// Releases all resources.
  Future<void> dispose() async {
    await stop();
    if (!_useWaveAudio) {
      final player = _player;
      final recorder = _recorder;
      _player = null;
      _recorder = null;
      if (player != null) {
        await player.closePlayer();
      }
      if (recorder != null) {
        await recorder.closeRecorder();
      }
    }
  }

  // ---------------------------------------------------------------------
  // Windows: wave_audio (WASAPI)
  // ---------------------------------------------------------------------

  Future<void> _startWaveAudio() async {
    _waCaptureSubscription = WaveAudio.captureEvents.listen((bytes) {
      final pcm = _bytesToInt16(bytes);
      _onCapture?.call(pcm);
    });
    try {
      await WaveAudio.startCapture();
      await WaveAudio.startPlayback(_sampleRate, 1);
    } catch (e) {
      await _waCaptureSubscription?.cancel();
      _waCaptureSubscription = null;
      throw StateError('CallAudioIO wave_audio failed to start: $e');
    }
    _started = true;
  }

  // ---------------------------------------------------------------------
  // Mobile: flutter_sound
  // ---------------------------------------------------------------------

  Future<void> _startFlutterSound() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      throw StateError('CallAudioIO: microphone permission denied: $mic');
    }
    _player = FlutterSoundPlayer();
    _recorder = FlutterSoundRecorder();

    try {
      await _player!.openPlayer();
      await _recorder!.openRecorder();
    } catch (e) {
      await _cleanupAfterStartFailure();
      throw StateError('CallAudioIO failed to open audio sessions: $e');
    }

    try {
      await _player!.startPlayerFromStream(
        codec: Codec.pcm16,
        interleaved: true,
        numChannels: 1,
        sampleRate: _sampleRate,
        bufferSize: _bufferSize,
      );
    } catch (e) {
      await _cleanupAfterStartFailure();
      throw StateError('CallAudioIO failed to start playback stream: $e');
    }

    _captureController = StreamController<Int16List>();
    _streamInt16Controller = StreamController<List<Int16List>>();
    _streamInt16Subscription = _streamInt16Controller!.stream.listen((chunks) {
      for (final chunk in chunks) {
        _captureController!.add(chunk);
      }
    });
    _captureSubscription = _captureController!.stream.listen((pcm) {
      _onCapture?.call(pcm);
    });

    try {
      await _recorder!.startRecorder(
        codec: Codec.pcm16,
        toStreamInt16: _streamInt16Controller!.sink,
        sampleRate: _sampleRate,
        numChannels: 1,
        audioSource: AudioSource.microphone,
      );
    } catch (e) {
      await _cleanupAfterStartFailure();
      throw StateError('CallAudioIO: microphone capture could not start: $e');
    }

    _started = true;
  }

  Future<void> _teardownStreaming() async {
    _captureSubscription?.cancel();
    _captureSubscription = null;
    await _captureController?.close();
    _captureController = null;
    _streamInt16Subscription?.cancel();
    _streamInt16Subscription = null;
    await _streamInt16Controller?.close();
    _streamInt16Controller = null;
    _onCapture = null;
  }

  Future<void> _cleanupAfterStartFailure() async {
    final player = _player;
    final recorder = _recorder;
    _player = null;
    _recorder = null;

    await _teardownStreaming();
    _started = false;

    if (player != null) {
      try {
        await player.stopPlayer();
      } catch (_) {}
      try {
        await player.closePlayer();
      } catch (_) {}
    }
    if (recorder != null) {
      try {
        await recorder.stopRecorder();
      } catch (_) {}
      try {
        await recorder.closeRecorder();
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------
  // PCM16 <-> little-endian byte conversions
  // ---------------------------------------------------------------------

  Int16List _bytesToInt16(Uint8List bytes) {
    final count = bytes.length >> 1;
    final out = Int16List(count);
    // Use ByteData: it is not aligned, so it tolerates the odd offsets the
    // plugin's event channel can produce (your typical Int16List.view would
    // throw "offset must be a multiple of BYTES_PER_ELEMENT").
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < count; i++) {
      out[i] = view.getInt16(i * 2, Endian.little);
    }
    return out;
  }

  Uint8List _int16ToBytes(Int16List pcm) {
    final out = Uint8List(pcm.length << 1);
    if (pcm.isNotEmpty) {
      final view = Int16List.view(out.buffer);
      view.setAll(0, pcm);
    }
    return out;
  }
}