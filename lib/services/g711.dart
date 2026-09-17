library;

import 'dart:typed_data';

/// G.711 μ-law codec (pure Dart, portable) — mirrors `G:\wave\src\audio.rs`.
/// Sample rate used by the Wave protocol is 8 kHz mono 16-bit PCM
/// (`protocol::G711_SAMPLE_RATE`), with one encoded byte per sample.

const int _bias = 0x84; // 132
const int _clip = 32635;

const List<int> _expLut = [
  0, 0, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3,
  4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
];

int encodeMulaw(int sample) {
  var s = sample;
  final sign = (s >> 8) & 0x80;
  if (sign != 0) s = -s;
  if (s > _clip) s = _clip;
  s += _bias;
  final exponent = _expLut[(s >> 7) & 0xFF];
  final mantissa = (s >> (exponent + 3)) & 0x0F;
  return (~(sign | (exponent << 4) | mantissa)) & 0xFF;
}

int decodeMulaw(int byte) {
  final u = (~byte) & 0xFF;
  final sign = u & 0x80;
  final exponent = (u >> 4) & 0x07;
  final mantissa = u & 0x0F;
  var sample = ((mantissa << 3) + _bias) << exponent;
  sample -= _bias;
  if (sign != 0) sample = -sample;
  return sample;
}

Uint8List mulawEncodeFrame(List<int> pcm) {
  final out = Uint8List(pcm.length);
  for (var i = 0; i < pcm.length; i++) {
    out[i] = encodeMulaw(pcm[i]);
  }
  return out;
}

Int16List mulawDecodeFrame(Uint8List bytes) {
  final out = Int16List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    out[i] = decodeMulaw(bytes[i]);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Capture-side gain (quality helper)
// ---------------------------------------------------------------------------

const double _agcTargetPeak = 0.70 * 32767.0;
const double _agcMaxGain = 3.0;
const int _agcFloor = 160;

/// Bounded peak normalization applied *before* μ-law encoding.
///
/// Quiet speech otherwise maps to the quietest μ-law steps and comes out
/// barely audible after the 8 kHz codec; scaling a frame's peak toward
/// [_agcTargetPeak] keeps loud speech unchanged while lifting quiet frames.
/// The gain is capped by [_agcMaxGain] and frames near silence ([_agcFloor])
/// are left alone so noise is not amplified into hiss. This only changes the
/// amplitude of the wire format (still G.711 μ-law 8 kHz mono), so it stays
/// fully interoperable with the Rust CLI.
Int16List agcBoost(List<int> pcm) {
  var peak = 0;
  for (final s in pcm) {
    final a = s < 0 ? -s : s;
    if (a > peak) peak = a;
  }
  if (peak <= 0 || peak < _agcFloor) {
    return Int16List.fromList(pcm);
  }
  var gain = _agcTargetPeak / peak;
  if (gain > _agcMaxGain) gain = _agcMaxGain;
  if (gain <= 1.0001) return Int16List.fromList(pcm);
  final out = Int16List(pcm.length);
  for (var i = 0; i < pcm.length; i++) {
    final v = (pcm[i] * gain).round();
    out[i] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
  }
  return out;
}
