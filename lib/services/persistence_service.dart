import 'dart:convert';
import 'dart:io';
import 'package:flutter_wave/models/friend.dart';
import 'package:flutter_wave/models/message.dart';
import 'package:path_provider/path_provider.dart';

class PersistenceService {
  static Future<Directory> _getDataDir() async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory('${appDir.path}${Platform.pathSeparator}wave_data');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> _getFile(String name) async {
    final dir = await _getDataDir();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  /// Crash-safe write: write to `<name>.tmp`, then swap over the real file.
  /// A torn write (power loss mid-write) can never leave a half-written final
  /// file, and a crash between delete+rename leaves the `.tmp` behind, which
  /// the loaders recover.
  static Future<void> _atomicWrite(File file, String content) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }

  /// Reads [file], first promoting a leftover `.tmp` when the real file is
  /// missing (crash between delete and rename). Returns null when neither
  /// exists.
  static Future<String?> _readOrNull(File file) async {
    final tmp = File('${file.path}.tmp');
    if (!await file.exists() && await tmp.exists()) {
      try {
        await tmp.rename(file.path);
      } catch (_) {}
    }
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  /// Moves a corrupt/unparseable data file aside so the next successful save
  /// cannot overwrite the only remaining copy (data survives for recovery).
  static Future<void> _quarantine(File file) async {
    try {
      if (await file.exists()) {
        final q =
            '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
        await file.rename(q);
      }
    } catch (_) {}
  }

  static Future<void> saveFriends(List<Friend> friends) async {
    final file = await _getFile('friends.json');
    final json = friends.map((f) => {
      'id': f.id,
      'name': f.name,
      'shortId': f.shortId,
      'note': f.note,
      'status': f.status.index,
      'createdAt': f.createdAt.toIso8601String(),
      'lastMessage': f.lastMessage,
      'lastMessageTime': f.lastMessageTime?.toIso8601String(),
      'unreadCount': f.unreadCount,
    }).toList();
    await _atomicWrite(file, jsonEncode(json));
  }

  static Future<List<Friend>> loadFriends() async {
    try {
      final file = await _getFile('friends.json');
      final content = await _readOrNull(file);
      if (content == null) return [];
      final json = jsonDecode(content) as List;
      return json.map((map) => Friend(
        id: map['id'],
        name: map['name'],
        shortId: map['shortId'],
        note: map['note'] ?? '',
        status: FriendStatus.values[map['status']],
        createdAt: DateTime.parse(map['createdAt']),
        lastMessage: map['lastMessage'],
        lastMessageTime: map['lastMessageTime'] != null
            ? DateTime.parse(map['lastMessageTime'])
            : null,
        unreadCount: map['unreadCount'] ?? 0,
      )).toList();
    } catch (e) {
      await _quarantine(await _getFile('friends.json'));
      return [];
    }
  }

  static Future<void> saveMessages(String chatId, List<Message> messages) async {
    final file = await _getFile('messages_$chatId.json');
    final json = messages.map((m) => {
      'id': m.id,
      'senderId': m.senderId,
      'receiverId': m.receiverId,
      'content': m.content,
      'timestamp': m.timestamp.toIso8601String(),
      'type': m.type.index,
      'isMe': m.isMe,
      'status': m.status.index,
      'fileName': m.fileName,
      'filePath': m.filePath,
      'fileSize': m.fileSize,
      'transferId': m.transferId,
      'played': m.played,
    }).toList();
    await _atomicWrite(file, jsonEncode(json));
  }

  static Future<List<Message>> loadMessages(String chatId) async {
    try {
      final file = await _getFile('messages_$chatId.json');
      final content = await _readOrNull(file);
      if (content == null) return [];
      final json = jsonDecode(content) as List;
      return json.map((map) => Message(
        id: map['id'],
        senderId: map['senderId'],
        receiverId: map['receiverId'],
        content: map['content'],
        timestamp: DateTime.parse(map['timestamp']),
        type: MessageType.values[map['type']],
        isMe: map['isMe'],
        status: MessageStatus.values[map['status']],
        fileName: map['fileName'],
        filePath: map['filePath'],
        fileSize: map['fileSize'],
        transferId: map['transferId'],
        played: map['played'] ?? false,
      )).toList();
    } catch (e) {
      await _quarantine(await _getFile('messages_$chatId.json'));
      return [];
    }
  }

  static Future<void> saveOutbox(List<Map<String, dynamic>> outbox) async {
    final file = await _getFile('outbox.json');
    await _atomicWrite(file, jsonEncode(outbox));
  }

  static Future<List<Map<String, dynamic>>> loadOutbox() async {
    try {
      final file = await _getFile('outbox.json');
      final content = await _readOrNull(file);
      if (content == null) return [];
      final json = jsonDecode(content) as List;
      return json.cast<Map<String, dynamic>>();
    } catch (e) {
      await _quarantine(await _getFile('outbox.json'));
      return [];
    }
  }

  static Future<void> saveThemeMode(String mode) async {
    final file = await _getFile('theme.json');
    await _atomicWrite(file, jsonEncode({'mode': mode}));
  }

  static Future<void> saveUpdateSettings(
      {String? url, String? lastSeenVersion}) async {
    final file = await _getFile('update.json');
    final existing = await loadUpdateSettings();
    await _atomicWrite(file, jsonEncode({
      'url': url ?? existing['url'],
      'lastSeenVersion': lastSeenVersion ?? existing['lastSeenVersion'],
    }));
  }

  static Future<Map<String, dynamic>> loadUpdateSettings() async {
    try {
      final file = await _getFile('update.json');
      final content = await _readOrNull(file);
      if (content == null) return {'url': '', 'lastSeenVersion': ''};
      final json = jsonDecode(content) as Map<String, dynamic>;
      return {
        'url': json['url'] ?? '',
        'lastSeenVersion': json['lastSeenVersion'] ?? '',
      };
    } catch (e) {
      await _quarantine(await _getFile('update.json'));
      return {'url': '', 'lastSeenVersion': ''};
    }
  }

  static Future<String> loadUpdateUrl() async =>
      (await loadUpdateSettings())['url'] as String? ?? '';

  static Future<String> loadLastSeenUpdateVersion() async =>
      (await loadUpdateSettings())['lastSeenVersion'] as String? ?? '';

  static Future<String> loadThemeMode() async {
    try {
      final file = await _getFile('theme.json');
      final content = await _readOrNull(file);
      if (content == null) return 'system';
      final json = jsonDecode(content) as Map<String, dynamic>;
      return json['mode'] ?? 'system';
    } catch (e) {
      await _quarantine(await _getFile('theme.json'));
      return 'system';
    }
  }

  static Future<void> clearAll() async {
    final dir = await _getDataDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
