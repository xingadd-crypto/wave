import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// Image prepared for the wire: optionally downscaled/re-encoded so a camera
/// photo (typically 4-10 MB) leaves the device as a JPEG of a few hundred KB.
class PreparedImage {
  final Uint8List data;
  final int width;
  final int height;
  final Uint8List thumbPng;
  final String name;

  PreparedImage(this.data, this.width, this.height, this.thumbPng, this.name);
}

/// Decodes [src] and returns a copy fit for sending over the wire:
/// the longest side is capped at [maxDim] px and the payload is shrunk to at
/// most [compactBytes] by re-encoding as JPEG (quality 85 -> 75 -> 60 -> 45,
/// then 15% downscale steps, always keeping the source aspect ratio), which
/// also flattens transparency onto a white background. Sources that `image`
/// cannot decode (HEIC, some WebP, ...) are decoded via `dart:ui` first.
/// When [forceJpg] is false, images that are already small and compact are
/// returned byte-for-byte. Returns null when [src] cannot be decoded.
Future<PreparedImage?> prepareImageForSend(
  Uint8List src,
  String name, {
  int maxDim = 2048,
  int compactBytes = 1536 * 1024,
  bool forceJpg = false,
}) async {
  var original = img.decodeImage(src);
  original ??= await _decodeWithDartUi(src);
  if (original == null) return null;
  final w = original.width;
  final h = original.height;
  if (w <= 0 || h <= 0) return null;

  final wantJpg = forceJpg ||
      name.toLowerCase().endsWith('.jpg') ||
      name.toLowerCase().endsWith('.jpeg');

  if (!forceJpg && w <= maxDim && h <= maxDim && src.length <= compactBytes) {
    final thumb = _thumbnail(img.copyResize(original,
        width: original.width, height: original.height));
    return PreparedImage(src, w, h, thumb, name);
  }

  img.Image scaled = original;
  if (w > maxDim || h > maxDim) {
    final f = maxDim / (w > h ? w : h);
    final tw = (w * f).round().clamp(1, maxDim);
    final th = (h * f).round().clamp(1, maxDim);
    scaled = img.copyResize(original,
        width: tw,
        height: th,
        interpolation: img.Interpolation.cubic);
  }
  final outName = wantJpg
      ? _withExtension(name, 'jpg')
      : _withExtension(name, 'png');
  final Uint8List data = wantJpg
      ? _encodeJpegWithinBudget(scaled, compactBytes)
      : Uint8List.fromList(img.encodePng(scaled));
  final thumb = _thumbnail(img.copyResize(scaled,
      width: scaled.width, height: scaled.height));
  return PreparedImage(data, scaled.width, scaled.height, thumb, outName);
}

/// Downscales [src] to the first JPEG encoding that fits under [budget] bytes,
/// trying quality 85/75/60/45 at each size and shrinking the longest side by
/// 15% per round (never below 800 px, aspect ratio preserved) until it fits.
Uint8List _encodeJpegWithinBudget(img.Image src, int budget) {
  const qualities = [85, 75, 60, 45];
  const minSide = 800.0;
  Uint8List data = Uint8List.fromList(img.encodeJpg(src, quality: 85));
  if (data.length <= budget) return data;

  var image = src;
  while (image.width > minSide || image.height > minSide) {
    final longest =
        image.width > image.height ? image.width : image.height;
    final f = (longest * 0.85).clamp(minSide, longest.toDouble()) / longest;
    final tw = (image.width * f).clamp(1.0, image.width.toDouble()).round();
    final th = (image.height * f).clamp(1.0, image.height.toDouble()).round();
    image = img.copyResize(image,
        width: tw,
        height: th,
        interpolation: img.Interpolation.cubic);
    for (var i = 0; i < qualities.length; i++) {
      data = Uint8List.fromList(img.encodeJpg(image, quality: qualities[i]));
      if (data.length <= budget) return data;
    }
  }
  return data;
}

/// Falls back to the platform image codec (Flutter's `dart:ui`) so formats the
/// pure-Dart `package:image` cannot parse (HEIC, some WebP, ...) are handled.
Future<img.Image?> _decodeWithDartUi(Uint8List src) async {
  try {
    final codec = await ui.instantiateImageCodec(src);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    final w = image.width;
    final h = image.height;
    if (w <= 0 || h <= 0) {
      image.dispose();
      return null;
    }
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    if (rgba == null) return null;
    final rgbaBytes =
        rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes);
    return img.Image.fromBytes(
      width: w,
      height: h,
      bytes: rgbaBytes.buffer,
      numChannels: 4,
    );
  } catch (_) {
    return null;
  }
}

String _withExtension(String name, String ext) {
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  return '$base.$ext';
}

Uint8List _thumbnail(img.Image scaled, {int maxDim = 32}) {
  var tw = scaled.width;
  var th = scaled.height;
  if (tw > maxDim || th > maxDim) {
    final f = maxDim / (tw > th ? tw : th);
    tw = (tw * f).round().clamp(1, maxDim);
    th = (th * f).round().clamp(1, maxDim);
  }
  final thumb = img.copyResize(scaled, width: tw, height: th);
  return Uint8List.fromList(img.encodePng(thumb));
}

/// Mirrors the CLI's `img::make_thumbnail` / `thumb_to_png`: decodes an image
/// (PNG/JPEG/GIF...) and returns its original dimensions plus a PNG-encoded
/// thumbnail whose longest side is at most [maxDim] px, aspect ratio preserved
/// and never upscaled (small images keep their source size).
class ImageMessageMeta {
  final int width;
  final int height;
  final Uint8List thumbPng;

  ImageMessageMeta(this.width, this.height, this.thumbPng);
}

/// Returns null when [data] cannot be decoded as an image.
Future<ImageMessageMeta?> decodeImageMessageMeta(
  Uint8List data, {
  int maxDim = 32,
}) async {
  try {
    final codec = await ui.instantiateImageCodec(data);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final img = frame.image;
    final w = img.width;
    final h = img.height;
    if (w <= 0 || h <= 0) {
      img.dispose();
      return null;
    }
    int tw = w;
    int th = h;
    if (w > maxDim || h > maxDim) {
      final f = maxDim / (w > h ? w : h);
      tw = (w * f).round().clamp(1, maxDim);
      th = (h * f).round().clamp(1, maxDim);
    }
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      img,
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final thumb = await recorder.endRecording().toImage(tw, th);
    final png = await thumb.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (png == null) return null;
    return ImageMessageMeta(
      w,
      h,
      Uint8List.view(png.buffer, png.offsetInBytes, png.lengthInBytes),
    );
  } catch (_) {
    return null;
  }
}