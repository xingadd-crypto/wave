import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_wave/services/qr_payload.dart';

/// Full-screen camera QR scanner. Pops with the raw QR payload string when a
/// valid Wave `wave:pk:…` payload (or a bare 64-hex key) is detected, or with
/// `null` when cancelled. On platforms without a usable camera (e.g. desktop)
/// a "paste instead" fallback is offered.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  StreamSubscription<BarcodeCapture>? _sub;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    final navigator = Navigator.of(context);
    _sub = _controller.barcodes.listen((capture) {
      if (_resolved) return;
      for (final barcode in capture.barcodes) {
        final raw = barcode.rawValue;
        if (raw != null && QrPayload.isValid(raw)) {
          _resolved = true;
          navigator.pop(raw);
          return;
        }
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan QR Code'),
        actions: [
          IconButton(
            tooltip: 'Torch',
            icon: const Icon(Icons.flash_on),
            onPressed: () async {
              try {
                await _controller.toggleTorch();
              } catch (_) {}
            },
          ),
          IconButton(
            tooltip: 'Switch camera',
            icon: const Icon(Icons.cameraswitch_outlined),
            onPressed: () async {
              try {
                await _controller.switchCamera();
              } catch (_) {}
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            errorBuilder: (context, error) => _buildCameraError(error),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 40,
            child: Center(
              child: SafeArea(
                child: TextButton.icon(
                  onPressed: _pasteInstead,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.black54,
                  ),
                  icon: const Icon(Icons.content_paste),
                  label: const Text('No camera? Paste the code payload'),
                ),
              ),
            ),
          ),
          const Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Text(
                  'Point the camera at the other device\u2019s QR code',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    backgroundColor: Colors.black54,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraError(MobileScannerException error) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.videocam_off, color: Colors.white70, size: 56),
          const SizedBox(height: 12),
          Text(
            'Camera unavailable.\n${error.errorCode.message}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _pasteInstead,
            icon: const Icon(Icons.content_paste),
            label: const Text('Paste QR data instead'),
          ),
        ],
      ),
    );
  }

  Future<void> _pasteInstead() async {
    final text = await Clipboard.getData(Clipboard.kTextPlain);
    final payload = text?.text?.trim();
    if (payload == null || payload.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clipboard is empty')),
        );
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(payload);
  }
}