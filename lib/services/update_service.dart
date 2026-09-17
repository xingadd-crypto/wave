import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_wave/services/app_version.dart';
import 'package:flutter_wave/services/persistence_service.dart';

/// Manifest payload served from the configured OTA source. Field layout:
///
/// ```json
/// {
///   "version": "1.0.26",
///   "notes": "what changed",
///   "windows":  { "url": "https://.../Wave_setup.exe", "sha256": "..." },
///   "android":  { "url": "https://.../app-arm64-v8a-release.apk", "sha256": "..." }
/// }
/// ```
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    this.notes,
    this.windowsUrl,
    this.windowsSha256,
    this.androidUrl,
    this.androidSha256,
  });

  final String version;
  final String? notes;
  final String? windowsUrl;
  final String? windowsSha256;
  final String? androidUrl;
  final String? androidSha256;

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> map(String key) =>
        json[key] is Map<String, dynamic> ? json[key] as Map<String, dynamic> : const {};
    final windows = map('windows');
    final android = map('android');
    return UpdateInfo(
      version: json['version']?.toString() ?? '',
      notes: json['notes']?.toString(),
      windowsUrl: windows['url']?.toString(),
      windowsSha256: windows['sha256']?.toString(),
      androidUrl: android['url']?.toString(),
      androidSha256: android['sha256']?.toString(),
    );
  }
}

/// Aggregated outcome of a check against the OTA manifest.
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.available,
    this.info,
    this.error,
    this.upToDate = false,
    this.skipped = false,
  });

  /// True when a newer version exists on the manifest.
  final bool available;

  /// The manifest info (null when the source could not be read).
  final UpdateInfo? info;

  /// Human-readable failure message (network/parse/compare errors).
  final String? error;

  /// True when running the latest version already.
  final bool upToDate;

  /// True when no OTA source is configured (checks are disabled).
  final bool skipped;

  /// URL to fetch for the current platform, or null if the manifest does not
  /// carry one for this platform.
  String? downloadUrlForPlatform() {
    if (Platform.isWindows) return info?.windowsUrl;
    if (Platform.isAndroid) return info?.androidUrl;
    return info?.androidUrl;
  }

  String? sha256ForPlatform() {
    if (Platform.isWindows) return info?.windowsSha256;
    if (Platform.isAndroid) return info?.androidSha256;
    return info?.androidSha256;
  }
}

/// OTA (over-the-air) update check + guided installer download.
///
/// The manifest URL is stored in settings; when it is empty the checks are
/// disabled (`UpdateCheckResult.skipped`). This keeps the feature inert until
/// the operator configures an update source. Downloads are verified against a
/// manifest-provided SHA-256 when present; the actual install is guided (the
/// app cannot silently replace itself) — a Windows installer is launched once
/// verified, an APK is placed in the app support directory for the user to
/// install from a file manager.
class UpdateService {
  static const Duration autoCheckInterval = Duration(hours: 24);

  static Future<UpdateCheckResult> checkForUpdate({String? manifestUrl}) async {
    final url = manifestUrl ?? await PersistenceService.loadUpdateUrl();
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return const UpdateCheckResult(available: false, skipped: true);
    }
    try {
      final info = await checkLatest(url: trimmed);
      if (info == null || info.version.isEmpty) {
        return const UpdateCheckResult(
          available: false,
          error: '无法获取更新信息：清单读取失败',
        );
      }
      if (!isNewerThan(appVersion, info.version)) {
        return UpdateCheckResult(available: false, upToDate: true, info: info);
      }
      return UpdateCheckResult(available: true, info: info);
    } catch (e) {
      return UpdateCheckResult(available: false, error: '检查更新失败：$e');
    }
  }

  /// Fetches and parses the OTA manifest at [url].
  static Future<UpdateInfo?> checkLatest({required String url}) async {
    final json = await _fetchJson(url);
    if (json == null) return null;
    return UpdateInfo.fromJson(json);
  }

  /// Dotted numeric version comparison: true when [candidate] represents a
  /// release newer than [current] (trailing numeric fields default to 0, so
  /// "1.0.25.1" > "1.0.25").
  static bool isNewerThan(String current, String candidate) {
    final a = _parts(current);
    final b = _parts(candidate);
    final len = math.max(a.length, b.length);
    for (var i = 0; i < len; i++) {
      final av = i < a.length ? a[i] : 0;
      final bv = i < b.length ? b[i] : 0;
      if (bv != av) return bv > av;
    }
    return false;
  }

  static List<int> _parts(String v) {
    return v
        .trim()
        .split('.')
        .map((e) => int.tryParse(e.trim().split('-').first) ?? 0)
        .toList();
  }

  /// Downloads [url] into [destPath], optionally verifying [sha256] hex. Throws
  /// on failure (including checksum mismatch). [onProgress] reports
  /// `(bytesDone, totalBytesOrLess-than-zero)`.
  static Future<void> downloadFile({
    required String url,
    required String destPath,
    String? sha256,
    void Function(int done, int total)? onProgress,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final file = File(destPath);
    await file.parent.create(recursive: true);
    try {
      var current = url;
      for (var hop = 0; hop < 8; hop++) {
        final request = await client
            .getUrl(Uri.parse(current))
            .timeout(const Duration(seconds: 20));
        final response = await request.close().timeout(const Duration(seconds: 30));
        final code = response.statusCode;
        if (code == HttpStatus.movedPermanently ||
            code == HttpStatus.found ||
            code == HttpStatus.seeOther ||
            code == HttpStatus.temporaryRedirect ||
            code == HttpStatus.permanentRedirect) {
          current = response.headers.value(HttpHeaders.locationHeader) ?? '';
          await response.drain<void>();
          if (current.isEmpty) throw StateError('重定向缺少 Location');
          continue;
        }
        if (code != HttpStatus.ok) {
          await response.drain<void>();
          throw HttpException('HTTP $code', uri: Uri.parse(current));
        }
        final total = response.contentLength;
        final sink = file.openWrite();
        var done = 0;
        try {
          await for (final chunk in response) {
            sink.add(chunk);
            done += chunk.length;
            onProgress?.call(done, total);
          }
        } finally {
          await sink.close();
        }
        if (sha256 != null && sha256.trim().isNotEmpty) {
          final computed = await _sha256Hex(file);
          if (computed.toLowerCase() != sha256.trim().toLowerCase()) {
            await file.delete();
            throw StateError('SHA-256 校验失败\n期望：$sha256\n实际：$computed');
          }
        }
        return;
      }
      throw StateError('重定向次数过多');
    } finally {
      client.close(force: true);
    }
  }

  /// Default destination file name for a freshly downloaded update package.
  static String packageFileName(String version) {
    final ext = Platform.isWindows ? '.exe' : '.apk';
    return 'wave_$version$ext';
  }

  /// Matches an update package file name like `wave_1.0.26.apk`,
  /// `wave-1.0.26.exe` or `wave_1.0.27.zip`.
  static final RegExp _updateNameRe = RegExp(
    r'^wave[_-]?(\d+(\.\d+)+)\.(apk|exe|zip)$',
    caseSensitive: false,
  );

  static bool isUpdatePackageName(String name) => _updateNameRe.hasMatch(name);

  static String? updateVersionFromName(String name) {
    final m = _updateNameRe.firstMatch(name);
    return m?.group(1);
  }

  /// Scans the local `updates/` directory (under app support — the same folder
  /// OTA downloads land in) for the newest package newer than [newerThan] that
  /// matches [platform]'s artifact type ('android' → .apk, 'windows' → .exe
  /// or .zip). Returns the file descriptor, or null when none exists — this is
  /// the "各平台对应各平台版本" selection used when serving a friend's request.
  static Future<({String path, String version, String fileName, int size})?>
      findLocalUpdatePackage({
    required String platform,
    required String newerThan,
  }) async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}${Platform.pathSeparator}updates');
      if (!await dir.exists()) return null;
      final exts =
          platform == 'android' ? const {'.apk'} : const {'.exe', '.zip'};

      String best = '';
      String bestVer = '';
      String bestFile = '';
      await for (final f in dir.list(followLinks: false)) {
        if (f is! File) continue;
        final name = f.uri.pathSegments.isEmpty
            ? ''
            : f.uri.pathSegments.last;
        final m = _updateNameRe.firstMatch(name);
        if (m == null) continue;
        if (!exts.contains('.${m.group(3)}'.toLowerCase())) continue;
        final ver = m.group(1)!;
        if (!isNewerThan(newerThan, ver)) continue;
        if (bestVer.isNotEmpty && !isNewerThan(bestVer, ver)) continue;
        best = f.path;
        bestVer = ver;
        bestFile = name;
      }
      if (best.isEmpty) return null;
      return (
        path: best,
        version: bestVer,
        fileName: bestFile,
        size: await File(best).length(),
      );
    } catch (_) {
      // Missing/unreadable updates dir must degrade to "no package" rather
      // than leaving the requester hanging on a timed-out request.
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _fetchJson(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      var current = url;
      for (var hop = 0; hop < 8; hop++) {
        final request = await client
            .getUrl(Uri.parse(current))
            .timeout(const Duration(seconds: 15));
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close().timeout(const Duration(seconds: 20));
        final code = response.statusCode;
        if (code == HttpStatus.movedPermanently ||
            code == HttpStatus.found ||
            code == HttpStatus.seeOther ||
            code == HttpStatus.temporaryRedirect ||
            code == HttpStatus.permanentRedirect) {
          current = response.headers.value(HttpHeaders.locationHeader) ?? '';
          await response.drain<void>();
          if (current.isEmpty) throw StateError('重定向缺少 Location');
          continue;
        }
        if (code != HttpStatus.ok) {
          await response.drain<void>();
          throw HttpException('HTTP $code', uri: Uri.parse(current));
        }
        final text = await response.transform(utf8.decoder).join();
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) return null;
        return decoded;
      }
      return null;
    } catch (e) {
      throw StateError(e.toString());
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _sha256Hex(File file) async {
    final fileBytes = await file.readAsBytes();
    final digest = await Sha256().hash(fileBytes);
    final sb = StringBuffer();
    for (final b in digest.bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Prepares the current app as an update package for friends.
  /// Creates a zip with manifest containing only the executable and changed data files.
  /// The zip includes a manifest.json with file list, versions, and SHA256 checksums.
  static Future<({bool ok, String message, String? filePath})> prepareUpdateForFriends() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}${Platform.pathSeparator}updates');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      if (Platform.isWindows) {
        final currentExe = Platform.resolvedExecutable;
        final src = File(currentExe);
        if (!await src.exists()) {
          return (ok: false, message: '无法找到当前可执行文件: $currentExe', filePath: null);
        }

        final zipName = 'wave_$appVersion.zip';
        final zipPath = '${dir.path}${Platform.pathSeparator}$zipName';
        final zipFile = File(zipPath);

        // Create update manifest
        final manifest = {
          'version': appVersion,
          'platform': 'windows',
          'timestamp': DateTime.now().toIso8601String(),
          'files': [
            {
              'path': 'wave.exe',
              'size': await src.length(),
              'sha256': await _sha256Hex(src),
            },
          ],
        };

        // Create zip with manifest and executable (in-memory encode, archive 4.x API)
        final manifestBytes = utf8.encode(jsonEncode(manifest));
        final exeBytes = await src.readAsBytes();
        final archiveZip = Archive()
          ..addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes))
          ..addFile(ArchiveFile('wave.exe', exeBytes.length, exeBytes));
        final zipData = ZipEncoder().encodeBytes(archiveZip);
        zipFile.createSync(recursive: true);
        await zipFile.writeAsBytes(zipData, flush: true);

        return (ok: true, message: '已准备好友更新包: $zipName', filePath: zipPath);
      } else if (Platform.isAndroid) {
        // On Android we cannot easily access the current APK path.
        // Return instructions for the user.
        final updatesDir = '${dir.path}';
        return (
          ok: true,
          message: 'Android 上无法自动获取当前 APK 路径。\n请手动将当前版本的 APK (wave_$appVersion.apk) 复制到:\n$updatesDir\n然后好友即可从你这里获取更新。',
          filePath: null
        );
      } else {
        return (ok: false, message: '不支持的平台: ${Platform.operatingSystem}', filePath: null);
      }
    } catch (e) {
      return (ok: false, message: '准备更新包失败: $e', filePath: null);
    }
  }

  /// Applies an update from a received zip file.
  /// Extracts with per-file progress callback.
  /// Returns the path to the new executable, or null on failure.
  static Future<({bool ok, String message, String? newExePath})> applyUpdateFromZip(
    String zipPath, {
    required void Function(int current, int total, String fileName) onProgress,
  }) async {
    try {
      final zipFile = File(zipPath);
      if (!await zipFile.exists()) {
        return (ok: false, message: '更新包不存在: $zipPath', newExePath: null);
      }

      // Read zip
      final zipBytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(zipBytes);

      // Find manifest
      final manifestFile = archive.findFile('manifest.json');
      if (manifestFile == null) {
        return (ok: false, message: '更新包缺少 manifest.json', newExePath: null);
      }
      final manifestJson = utf8.decode(manifestFile.content as List<int>);
      final manifest = jsonDecode(manifestJson) as Map<String, dynamic>;

      final myPlat = Platform.isAndroid ? 'android' : 'windows';
      final pkgPlatform = manifest['platform'];
      if (pkgPlatform != null && '$pkgPlatform' != myPlat) {
        return (ok: false, message: '更新包平台($pkgPlatform)与本机($myPlat)不符',
            newExePath: null);
      }
      final pkgVersion = manifest['version'] as String?;
      if (pkgVersion == null || pkgVersion.trim().isEmpty) {
        return (ok: false, message: '更新包缺少版本号', newExePath: null);
      }
      if (!isNewerThan(appVersion, pkgVersion.trim())) {
        return (ok: false,
            message: '更新包版本(v$pkgVersion)不高于当前版本(v$appVersion)',
            newExePath: null);
      }

      final files = manifest['files'] as List<dynamic>;
      final totalFiles = files.length;
      int currentFile = 0;

      final support = await getApplicationSupportDirectory();
      final updatesDir = Directory('${support.path}${Platform.pathSeparator}updates');
      if (!await updatesDir.exists()) {
        await updatesDir.create(recursive: true);
      }

      // Extract each file
      for (final fileInfo in files) {
        currentFile++;
        final relPath = fileInfo['path'] as String;
        if (relPath.isEmpty ||
            relPath.contains('..') ||
            relPath.startsWith('/') ||
            relPath.startsWith('\\') ||
            RegExp(r'^[A-Za-z]:').hasMatch(relPath)) {
          return (ok: false,
              message: '更新包包含非法文件路径: $relPath', newExePath: null);
        }
        final expectedSize = fileInfo['size'] as int;
        final expectedSha256 = fileInfo['sha256'] as String;

        final archiveFile = archive.findFile(relPath);
        if (archiveFile == null) {
          return (ok: false, message: '更新包中缺少文件: $relPath', newExePath: null);
        }

        final destPath = '${Directory.current.path}${Platform.pathSeparator}$relPath';
        final destFile = File(destPath);
        await destFile.parent.create(recursive: true);
        await destFile.writeAsBytes(archiveFile.content as List<int>);
        onProgress(currentFile, totalFiles, relPath);

        // Verify size
        final actualSize = await destFile.length();
        if (actualSize != expectedSize) {
          return (ok: false, message: '文件大小不匹配: $relPath (期望 $expectedSize, 实际 $actualSize)', newExePath: null);
        }

        // Verify checksum
        final actualSha256 = await _sha256Hex(destFile);
        if (actualSha256 != expectedSha256) {
          return (ok: false, message: '文件校验失败: $relPath', newExePath: null);
        }
      }

      // On Windows, the new executable is wave.exe in current directory
      if (Platform.isWindows) {
        final newExe = File('${Directory.current.path}${Platform.pathSeparator}wave.exe');
        if (await newExe.exists()) {
          return (ok: true, message: '更新包已就绪，重启后生效', newExePath: newExe.path);
        }
      }

      return (ok: false, message: '更新应用完成但未找到新可执行文件', newExePath: null);
    } catch (e) {
      return (ok: false, message: '应用更新失败: $e', newExePath: null);
    }
  }
}