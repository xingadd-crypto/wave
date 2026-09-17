import 'dart:io';

import 'package:gal/gal.dart';

/// Saves an image file to the platform photo gallery.
///
/// - Windows: copies the file into `%USERPROFILE%\Pictures\Wave` and returns
///   the destination path.
/// - Android / iOS: inserts the image into the device photo library via
///   MediaStore / the photos API (`gal`, requesting access if needed) and
///   returns `'gallery'`.
/// - Anything else: unsupported.
///
/// Returns null when the image could not be saved.
class GallerySaver {
  static Future<String?> saveImage(String srcPath, {String? album}) async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        if (!await Gal.hasAccess()) {
          try {
            await Gal.requestAccess();
          } catch (_) {}
        }
        if (!await Gal.hasAccess()) return null;
        await Gal.putImage(srcPath, album: album);
        return 'gallery';
      } else if (Platform.isWindows) {
        return _saveWindows(srcPath);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static Future<String?> _saveWindows(String srcPath) async {
    var profile = Platform.environment['USERPROFILE'];
    if (profile == null || profile.isEmpty) {
      profile = 'C:\\';
    }
    final dir = Directory('$profile\\Pictures\\Wave');
    await dir.create(recursive: true);
    final src = File(srcPath);
    if (!await src.exists()) return null;
    final dest = File('${dir.path}\\${_basename(srcPath)}');
    await src.copy(dest.path);
    return dest.path;
  }

  static String _basename(String p) {
    final norm = p.replaceAll('\\', '/');
    final i = norm.lastIndexOf('/');
    return i >= 0 ? norm.substring(i + 1) : p;
  }
}