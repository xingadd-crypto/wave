import 'dart:math' as math;

import 'package:flutter/material.dart';

/// iMessage-style animated voice waveform, shared by the playback bubble and
/// the voice-recording HUD.
///
/// Bars follow an organic pseudo-random pattern; while [animate] is true they
/// "dance" on a repeating loop. Bars whose index falls below
/// `progress * [bars]` are painted with [color] (played/elapsed region) and
/// the rest with [dimColor], giving a subtle playback-fill effect.
class VoiceWaveform extends StatefulWidget {
  final Color color;
  final Color dimColor;
  final int bars;
  final double height;
  final bool animate;
  final double progress;

  const VoiceWaveform({
    super.key,
    required this.color,
    required this.dimColor,
    this.bars = 12,
    this.height = 16,
    this.animate = false,
    this.progress = 0,
  });

  static const List<double> _pattern = [
    0.35, 0.7, 0.5, 0.95, 0.45, 0.3,
    0.62, 0.82, 0.4, 0.55, 0.75, 0.48,
  ];

  @override
  State<VoiceWaveform> createState() => _VoiceWaveformState();
}

class _VoiceWaveformState extends State<VoiceWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.animate) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(VoiceWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.animate && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double _barHeight(int index) {
    final base = VoiceWaveform._pattern[index % VoiceWaveform._pattern.length];
    double h;
    if (widget.animate) {
      final t = 2 * math.pi * _ctrl.value;
      final dance = 0.62 + 0.38 * math.sin(t + index * 0.9);
      h = widget.height * base * dance;
    } else {
      h = widget.height * base;
    }
    if (h < 2) h = 2;
    if (h > widget.height) h = widget.height;
    return h;
  }

  @override
  Widget build(BuildContext context) {
    final filledBars = widget.progress * widget.bars;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < widget.bars; i++)
              Container(
                width: 3,
                height: _barHeight(i),
                margin: EdgeInsets.only(right: i == widget.bars - 1 ? 0 : 2),
                decoration: BoxDecoration(
                  color: i < filledBars ? widget.color : widget.dimColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        );
      },
    );
  }
}