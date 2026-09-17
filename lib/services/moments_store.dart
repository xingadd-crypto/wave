import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Local persistence for the moments (social feed) feature.
///
/// Everything is pull-based: my own posts live in `my_moments.json`, each
/// friend's cached copy in `moments_<friendHex>.json`, and per-friend "last
/// seen" cursors in `moment_cursor_<friendHex>.json` so a later refresh only
/// pulls newer posts. Images are stored on disk keyed by
/// `<ownerHex>_<postId>_<index>` so they can be shown without re-fetching.
class MomentsStore {
  /// Moments cache bound (per friend / own feed): keep only the newest batch —
  /// one screenful, so the on-device cache stays small and only the latest
  /// data is retained. Older posts are pulled from the author on demand
  /// ("load more") instead of being stored locally.
  static const int maxCachedPosts = 10;

  /// Own feed bound: same "latest batch only" policy as friends.
  static const int maxMyPosts = 10;

  static Future<Directory> _getDataDir() async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory('${appDir.path}${Platform.pathSeparator}wave_data');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> _getMomentsDir() async {
    final dataDir = await _getDataDir();
    final dir = Directory('${dataDir.path}${Platform.pathSeparator}moments');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _getFile(String name) async {
    final dir = await _getMomentsDir();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  static String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');

  /// Keeps the newest [max] posts (sorted newest-first), trimming only past the
  /// count cap — never on recency grounds — so the on-device cache stays
  /// bounded without time-gating the feed.
  static List<Map<String, dynamic>> boundPosts(List<Map<String, dynamic>> posts,
      {required int max}) {
    if (posts.length <= max) return posts;
    final sorted = [...posts]
      ..sort((a, b) => (b['ts'] as int? ?? 0).compareTo(a['ts'] as int? ?? 0));
    return sorted.sublist(0, max);
  }

  // ── My own posts ─────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> loadMyMoments() async {
    return _loadJson('my_moments.json');
  }

  static Future<void> saveMyMoments(List<Map<String, dynamic>> posts) async {
    await _saveJson('my_moments.json', boundPosts(posts, max: maxMyPosts));
  }

  // ── A friend's posts (cached copy) ───────────────────────

  static Future<List<Map<String, dynamic>>> loadFriendMoments(String friendHex) async {
    return _loadJson('moments_${_sanitize(friendHex)}.json');
  }

  static Future<void> saveFriendMoments(
      String friendHex, List<Map<String, dynamic>> posts) async {
    await _saveJson('moments_${_sanitize(friendHex)}.json',
        boundPosts(posts, max: maxCachedPosts));
  }

  // ── Per-friend incremental cursor ─────────────────────────

  static Future<int> loadCursor(String friendHex) async {
    final list = await _loadJson('moment_cursor_${_sanitize(friendHex)}.json');
    if (list.isEmpty) return 0;
    final v = list.first['ts'];
    return v is int ? v : 0;
  }

  static Future<void> saveCursor(String friendHex, int ts) async {
    await _saveJson('moment_cursor_${_sanitize(friendHex)}.json', [
      {'ts': ts}
    ]);
  }

  // ── My deleted post ids (propagated to friends via feeds) ─

  static Future<List<String>> loadDeletedMyPostIds() async {
    final list = await _loadJson('my_deleted_moments.json');
    return list.map((e) => e['id'] as String? ?? '').where((e) => e.isNotEmpty).toList();
  }

  static Future<void> saveDeletedMyPostIds(List<String> ids) async {
    await _saveJson('my_deleted_moments.json',
        ids.map((id) => {'id': id}).toList());
  }

  // ── Image cache ───────────────────────────────────────────

  static String imageKey(String ownerHex, String postId, int index) =>
      '${_sanitize(postId)}_$index';

  static Future<Directory> _getOwnerDir(String ownerHex) async {
    final dir = await _getMomentsDir();
    final ownerDir =
        Directory('${dir.path}${Platform.pathSeparator}${_sanitize(ownerHex)}');
    if (!await ownerDir.exists()) await ownerDir.create(recursive: true);
    return ownerDir;
  }

  static Future<File> imageFile(String ownerHex, String postId, int index) async {
    final dir = await _getOwnerDir(ownerHex);
    return File('${dir.path}${Platform.pathSeparator}${imageKey(ownerHex, postId, index)}.bin');
  }

  static Future<bool> imageExists(String ownerHex, String postId, int index) async {
    final f = await imageFile(ownerHex, postId, index);
    return f.exists();
  }

  static Future<bool> saveImage(
      String ownerHex, String postId, int index, List<int> bytes) async {
    try {
      final f = await imageFile(ownerHex, postId, index);
      await f.writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> deletePostImages(
      String ownerHex, String postId, int count) async {
    for (var i = 0; i < count; i++) {
      try {
        final f = await imageFile(ownerHex, postId, i);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// Garbage-collects image files whose post is no longer in the cache (was
  /// trimmed past the cache cap, or deleted). Runs per owner directory.
  static Future<void> pruneOrphanedImages(String myHex) async {
    try {
      final dir = await _getMomentsDir();
      final ownerDirs = dir.listSync().whereType<Directory>().toList();
      if (ownerDirs.isEmpty) return;

      final my = await loadMyMoments();
      final myIds = my
          .map((p) => _sanitize(p['id'] as String? ?? ''))
          .where((s) => s.isNotEmpty)
          .toSet();

      for (final ownerDir in ownerDirs) {
        final owner = _sanitize(
            ownerDir.path.split(Platform.pathSeparator).last);
        final Set<String> keptIds;
        if (owner == _sanitize(myHex)) {
          keptIds = myIds;
        } else {
          final posts = await _loadJson('moments_$owner.json');
          keptIds = posts
              .map((p) => _sanitize(p['id'] as String? ?? ''))
              .where((s) => s.isNotEmpty)
              .toSet();
        }
        if (keptIds.isEmpty && owner != _sanitize(myHex)) {
          // No cached post and json absent -> stale owner dir entirely.
          try {
            await ownerDir.delete(recursive: true);
          } catch (_) {}
          continue;
        }
        for (final f in ownerDir.listSync().whereType<File>()) {
          final name = f.uri.pathSegments.last;
          if (!name.endsWith('.bin')) continue;
          final tokens = name.replaceAll('.bin', '').split('_');
          if (tokens.length < 2) continue;
          final id = tokens.sublist(0, tokens.length - 1).join('_');
          if (!keptIds.contains(id)) {
            try {
              await f.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  // ── Helpers ───────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> _loadJson(String name) async {
    try {
      final f = await _getFile(name);
      if (!await f.exists()) return [];
      final content = await f.readAsString();
      final json = jsonDecode(content) as List;
      return json.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveJson(String name, List<Map<String, dynamic>> list) async {
    try {
      final f = await _getFile(name);
      await f.writeAsString(jsonEncode(list));
    } catch (_) {}
  }
}
