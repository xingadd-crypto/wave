import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_wave/services/image_message_io.dart';

Future<Uint8List> _makePng(int w, int h, ui.Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = color,
  );
  final img = await recorder.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return Uint8List.view(data!.buffer, data.offsetInBytes, data.lengthInBytes);
}

void main() {
  group('decodeImageMessageMeta (send-side thumbnail, mirrors CLI img.rs)', () {
    test('returns original dims and a valid thumb for small images', () async {
      final png = await _makePng(20, 16, const ui.Color(0xFF00FF00));
      final meta = await decodeImageMessageMeta(png);
      expect(meta, isNotNull);
      expect(meta!.width, 20);
      expect(meta.height, 16);
      // Small image: never upscaled, thumb stays at source size.
      expect(meta.thumbPng, isNotEmpty);
      final codec = await ui.instantiateImageCodec(meta.thumbPng);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 20);
      expect(frame.image.height, 16);
      frame.image.dispose();
    });

    test('downscales large images to 鈮?2px preserving aspect', () async {
      final png = await _makePng(800, 400, const ui.Color(0xFF0000FF));
      final meta = await decodeImageMessageMeta(png);
      expect(meta, isNotNull);
      expect(meta!.width, 800);
      expect(meta.height, 400);
      final codec = await ui.instantiateImageCodec(meta.thumbPng);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 32);
      expect(frame.image.height, 16);
      frame.image.dispose();
    });

    test('rejects non-image bytes', () async {
      final meta =
          await decodeImageMessageMeta(Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(meta, isNull);
    });
  });
}

