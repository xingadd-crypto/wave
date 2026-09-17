import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_wave/services/iroh_service.dart';

/// Full-screen voice call UI. Driven primarily by `IrohService.callEventStream`
/// so it shows the correct controls for every phase (incoming ring, outgoing
/// ring, active) and pops itself once the call reaches `CallPhase.idle`.
/// Initial state is passed in via [initialEvent] so the screen renders
/// immediately even if a state change arrives mid-frame.
class CallScreen extends StatefulWidget {
  final CallEvent? initialEvent;

  const CallScreen({super.key, this.initialEvent});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final IrohService _iroh = IrohService();
  StreamSubscription<CallEvent>? _sub;

  CallPhase _phase = CallPhase.idle;
  String? _peerName;
  String? _peerShortId;
  String? _reason;
  String _elapsed = '00:00';
  Timer? _timer;
  DateTime? _connectedAt;

  @override
  void initState() {
    super.initState();
    final ev = widget.initialEvent;
    if (ev != null) {
      _phase = ev.phase;
      _peerName = ev.peerName;
      _peerShortId = ev.peerShortId;
      _reason = ev.reason;
    }
    _sub = _iroh.callEventStream.listen(_onEvent);
    _syncTimer();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  void _onEvent(CallEvent e) {
    if (!mounted) return;
    setState(() {
      _phase = e.phase;
      _peerName = e.peerName ?? _peerName;
      _peerShortId = e.peerShortId ?? _peerShortId;
      _reason = e.reason;
      if (e.phase == CallPhase.active) {
        _connectedAt ??= DateTime.now();
        _startTimer();
      } else {
        _connectedAt = null;
      }
    });
    if (e.phase == CallPhase.idle) {
      _showEndedMessage();
      _pop();
    }
  }

  void _syncTimer() {
    if (_phase == CallPhase.active) {
      _connectedAt ??= DateTime.now();
      _startTimer();
    } else {
      _timer?.cancel();
      _elapsed = '00:00';
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final start = _connectedAt ?? DateTime.now();
      final d = DateTime.now().difference(start);
      final mm = d.inMinutes.toString().padLeft(2, '0');
      final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
      setState(() => _elapsed = '$mm:$ss');
    });
  }

  void _showEndedMessage() {
    if (_reason == null || _reason!.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Call ended: $_reason'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _pop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  void _answer() => _iroh.answerIncomingCall(true);
  void _decline() => _iroh.answerIncomingCall(false);
  void _cancel() => _iroh.endActiveCall();
  void _hangUp() => _iroh.endActiveCall();

  String get _displayName {
    final base = (_peerName?.isNotEmpty ?? false)
        ? _peerName!
        : (_peerShortId?.isNotEmpty ?? false)
            ? _peerShortId!
            : 'Unknown';
    final sid = (_peerShortId?.isNotEmpty ?? false)
        ? '  #$_peerShortId'
        : '';
    return '$base$sid';
  }

  String get _title {
    switch (_phase) {
      case CallPhase.incomingRing:
        return 'Incoming Voice Call';
      case CallPhase.outgoingRing:
        return 'Calling…';
      case CallPhase.active:
        return 'Voice Call';
      case CallPhase.idle:
        return 'Call Ended';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Container(
        width: 380,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.indigo.shade900,
              Colors.indigo.shade800,
              Colors.indigo.shade700,
            ],
          ),
          borderRadius: BorderRadius.circular(24),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _title,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 32),
                CircleAvatar(
                  radius: 48,
                  backgroundColor: Colors.white24,
                  child: Icon(
                    Icons.person,
                    size: 60,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    _displayName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _statusLabel(),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 16,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 32),
                _buildControls(),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _statusLabel() {
    switch (_phase) {
      case CallPhase.incomingRing:
        return 'Incoming call…';
      case CallPhase.outgoingRing:
        return 'Ringing…';
      case CallPhase.active:
        return _elapsed;
      case CallPhase.idle:
        return 'Call ended';
    }
  }

  Widget _buildControls() {
    switch (_phase) {
      case CallPhase.incomingRing:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _roundAction(
              icon: Icons.call_end,
              label: 'Decline',
              color: Colors.redAccent,
              onTap: _decline,
            ),
            _roundAction(
              icon: Icons.call,
              label: 'Answer',
              color: Colors.greenAccent.shade700,
              onTap: _answer,
            ),
          ],
        );
      case CallPhase.outgoingRing:
        return _roundAction(
          icon: Icons.call_end,
          label: 'Cancel',
          color: Colors.redAccent,
          onTap: _cancel,
        );
      case CallPhase.active:
        return _roundAction(
          icon: Icons.call_end,
          label: 'Hang up',
          color: Colors.redAccent,
          onTap: _hangUp,
        );
      case CallPhase.idle:
        return const SizedBox.shrink();
    }
  }

  Widget _roundAction({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ],
    );
  }
}
