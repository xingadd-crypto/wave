import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_sound/public/flutter_sound.dart';
import 'package:ggwave_native/ggwave_native.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wave_audio/wave_audio.dart';

import 'qr_payload.dart';

/// Data-over-sound (ggwave) transfer for the offline add-friend flow.
///
/// Encodes a `wave:pk:` payload (or bare 64-char hex) into PCM16 and plays it
/// through the speaker, or records the microphone and decodes any sound code
/// emitted by a nearby device. This is the voice sibling of the QR flow — the
/// same payload codec ([QrPayload]) is used, so a code sent as sound can also
/// be scanned or pasted and vice versa.
///
/// Operating format: 16-bit little-endian PCM, mono, 48 kHz (ggwave's
/// ultrasonic protocol; frequencies land between ~15 and ~22 kHz on the
/// ultrasonic band, or ~2-9 kHz on the audible band).
///
/// Windows uses the [WaveAudio] WASAPI plugin (flutter_sound's Windows plugin
/// is non-functional); Android/iOS use flutter_sound.
class Ultrasonic {
  static const int sampleRate = GgwaveNative.sampleRate;

  static bool get _useWaveAudio => Platform.isWindows;

  // flutter_sound state (mobile).
  FlutterSoundRecorder? _recorder;
  FlutterSoundPlayer? _player;
  StreamController<List<Int16List>>? _streamController;
  StreamSubscription<List<Int16List>>? _streamSubscription;

  // wave_audio state (Windows).
  StreamSubscription<Uint8List>? _waSubscription;

  // Accumulated recorded PCM16 (mono) as raw little-endian bytes. Accumulating
  // bytes instead of boxed samples avoids ~300k boxed ints for a 48 kHz listen
  // and a final Int16List.fromList copy.
  final BytesBuilder _pcm = BytesBuilder(copy: false);

  int _durationMs(int samples) => samples * 1000 ~/ sampleRate;

  /// Encodes [payload] (falling back to progressively shorter shapes when the
  /// full one exceeds ggwave's 140-byte variable limit) and plays it once.
  ///
  /// [audible] switches from the (default) ultrasonic band to an audible-tone
  /// band for speakers/mics that roll off above 15 kHz. Returns the played
  /// duration in milliseconds, or 0 when nothing could be played. Playback is
  /// stopped automatically shortly after the buffer ends.
  Future<int> playPayload(String payload, {bool audible = false}) async {
    final candidates = <String>[payload];
    final parsed = QrPayload.parse(payload);
    if (parsed != null) {
      final hex = parsed['p']!;
      final noName = QrPayload.build(publicKeyHex: hex, shortId: parsed['s']);
      if (noName != payload) candidates.add(noName);
      if (hex != payload) candidates.add(hex);
    }

    Uint8List? pcm;
    for (final candidate in candidates) {
      pcm = await GgwaveNative.encode(candidate, audible: audible);
      if (pcm != null && pcm.isNotEmpty) break;
    }
    if (pcm == null || pcm.isEmpty) return 0;
    // Play the code twice back-to-back: the decode side only inspects audio at
    // the start of its capture, so the listener's recorder must begin at (or
    // just before) a code onset. Repeating guarantees a full code starts
    // shortly after any point in the playback window.
    final doubledPcm = Uint8List(pcm.length * 2);
    doubledPcm.setRange(0, pcm.length, pcm);
    doubledPcm.setRange(pcm.length, pcm.length * 2, pcm);
    final ms = _durationMs(doubledPcm.length ~/ 2);

    if (_useWaveAudio) {
      try {
        await WaveAudio.startPlayback(sampleRate, 1);
        WaveAudio.playAsync(doubledPcm);
      } catch (_) {
        return 0;
      }
    } else {
      final player = _player ??= FlutterSoundPlayer();
      try {
        await player.openPlayer();
        await player.startPlayerFromStream(
          codec: Codec.pcm16,
          interleaved: true,
          numChannels: 1,
          sampleRate: sampleRate,
          bufferSize: 16384,
        );
        final sink = player.uint8ListSink;
        if (sink == null) return 0;
        sink.add(doubledPcm);
      } catch (_) {
        return 0;
      }
    }

    // Let the whole buffer drain before stopping (a little extra for safety).
    await Future<void>.delayed(Duration(milliseconds: ms + 150));
    await stopPlayback();
    return ms;
  }

  /// Stops in-progress playback (safe when nothing is playing).
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

  /// Records the microphone for [durationMs] and returns the decoded payload
  /// string, or null when nothing was heard/decoded. The microphone is always
  /// released before returning.
  Future<String?> listenAndDecode({int durationMs = 10000}) async {
    _pcm.clear();

    if (_useWaveAudio) {
      try {
        await WaveAudio.startCapture(sampleRate: sampleRate, numChannels: 1);
      } catch (_) {
        return null;
      }
      _waSubscription = WaveAudio.captureEvents.listen(_collect);
      try {
        await Future<void>.delayed(Duration(milliseconds: durationMs));
      } finally {
        await _waSubscription?.cancel();
        _waSubscription = null;
        await WaveAudio.stopCapture();
      }
    } else {
      _recorder = FlutterSoundRecorder();
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) return null;
      _streamController = StreamController<List<Int16List>>();
      _streamSubscription = _streamController!.stream.listen((chunks) {
        for (final chunk in chunks) {
          if (chunk.isEmpty) continue;
          final n = chunk.length << 1;
          final b = Uint8List(n);
          Int16List.view(b.buffer).setAll(0, chunk);
          _pcm.add(b);
        }
      });
      try {
        await _recorder!.openRecorder();
        await _recorder!.startRecorder(
          codec: Codec.pcm16,
          toStreamInt16: _streamController!.sink,
          sampleRate: sampleRate,
          numChannels: 1,
          audioSource: AudioSource.microphone,
        );
        await Future<void>.delayed(Duration(milliseconds: durationMs));
        await _streamSubscription?.cancel();
        _streamSubscription = null;
        await _streamController?.close();
        _streamController = null;
        await _recorder?.stopRecorder();
      } catch (_) {
        await _streamSubscription?.cancel();
        _streamSubscription = null;
        try {
          await _streamController?.close();
        } catch (_) {}
        _streamController = null;
        // Also release the recorder session so a failed start can never leave
        // the microphone held open.
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
        return null;
      }
    }

    final bytes = _pcm.takeBytes();
    if (bytes.isEmpty) return null;

    return await _sweepDecode(bytes);
  }

  /// Decodes [bytes] once from the start, then retries from shifted offsets
  /// (one frame at a time). The wire decoder only inspects the very start of
  /// the buffer, so a code whose onset landed shortly after the recording
  /// started would otherwise never be found. Sliding the window catches a full
  /// code anywhere within the first few seconds of the capture.
  Future<String?> _sweepDecode(Uint8List bytes) async {
    final direct = await GgwaveNative.decode(bytes);
    if (direct != null && direct.isNotEmpty) return direct;

    const frameBytes = 2048; // 1024 samples, 16-bit mono
    final windowBytes = (sampleRate * 3.0).round() * 2; // 3 s per attempt
    final sweepBytes = (sampleRate * 3.0).round() * 2; // look across first 3 s
    final upper = bytes.length < sweepBytes ? bytes.length : sweepBytes;
    for (var off = frameBytes; off + frameBytes < bytes.length && off < upper;
        off += frameBytes) {
      final end = off + windowBytes < bytes.length ? off + windowBytes : bytes.length;
      final chunk = Uint8List.sublistView(bytes, off, end);
      final found = await GgwaveNative.decode(chunk);
      if (found != null && found.isNotEmpty) return found;
    }
    return null;
  }

  void _collect(Uint8List bytes) {
    if (bytes.isEmpty) return;
    // PCM16 is 2 bytes/sample; keep the trailing odd byte out so the buffer
    // stays a valid Int16Views/ggwave input.
    _pcm.add(Uint8List.sublistView(bytes, 0, bytes.length & ~1));
  }

  /// Releases microphone/playback resources owned by this instance.
  Future<void> dispose() async {
    if (_useWaveAudio) {
      await _waSubscription?.cancel();
      _waSubscription = null;
      try {
        await WaveAudio.stopCapture();
      } catch (_) {}
      await stopPlayback();
      _pcm.clear();
      return;
    }
    _streamSubscription?.cancel();
    _streamSubscription = null;
    try {
      await _streamController?.close();
    } catch (_) {}
    _streamController = null;
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
    _pcm.clear();
  }
}