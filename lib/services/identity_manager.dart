import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:iroh_flutter/iroh_flutter.dart';
import 'package:path_provider/path_provider.dart';

class UserIdentity {
  final String secretKeyHex;
  final String publicKeyHex;
  String nickname;
  String? shortId;
  String? serverAddress;
  String? moonServerTicket;

  UserIdentity({
    required this.secretKeyHex,
    required this.publicKeyHex,
    required this.nickname,
    this.shortId,
    this.serverAddress,
    this.moonServerTicket,
  });

  Uint8List get secretKeyBytes => _hexDecode(secretKeyHex);
  Uint8List get publicKeyBytes => _hexDecode(publicKeyHex);
  SecretKey get secretKey => SecretKey.fromBytes(secretKeyBytes);
  PublicKey get publicKeyObj => PublicKey.fromHex(publicKeyHex);

  static Uint8List _hexDecode(String hexStr) {
    final result = Uint8List(hexStr.length ~/ 2);
    for (var i = 0; i < hexStr.length; i += 2) {
      result[i ~/ 2] = int.parse(hexStr.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
    'secretKeyHex': secretKeyHex,
    'publicKeyHex': publicKeyHex,
    'nickname': nickname,
    'shortId': shortId,
    'serverAddress': serverAddress,
    'moonServerTicket': moonServerTicket,
  };

  factory UserIdentity.fromJson(Map<String, dynamic> json) => UserIdentity(
    secretKeyHex: json['secretKeyHex'] ?? '',
    publicKeyHex: json['publicKeyHex'] ?? '',
    nickname: json['nickname'] ?? '',
    shortId: json['shortId'],
    serverAddress: json['serverAddress'],
    moonServerTicket: json['moonServerTicket'],
  );
}

class IdentityManager {
  static Future<File> _getFile() async {
    final dir = await getApplicationSupportDirectory();
    final dataDir = Directory('${dir.path}${Platform.pathSeparator}wave_data');
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }
    return File('${dataDir.path}${Platform.pathSeparator}identity.json');
  }

  static Future<File> _getMoonTicketFile() async {
    final dir = await getApplicationSupportDirectory();
    final dataDir = Directory('${dir.path}${Platform.pathSeparator}wave_data');
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }
    return File('${dataDir.path}${Platform.pathSeparator}moon_ticket');
  }

  UserIdentity? _currentIdentity;
  UserIdentity? get currentIdentity => _currentIdentity;
  bool get hasIdentity => _currentIdentity != null;

  Future<void> initialize() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) {
        // A crash between the tmp-write and rename steps of _save leaves the
        // .tmp behind; promote it so the identity is never silently lost.
        final tmp = File('${file.path}.tmp');
        if (await tmp.exists()) {
          await tmp.rename(file.path);
        } else {
          return;
        }
      }
      final content = await file.readAsString();
      final map = jsonDecode(content) as Map<String, dynamic>;
      _currentIdentity = UserIdentity.fromJson(map);

      if (_currentIdentity!.moonServerTicket == null) {
        final ticketFile = await _getMoonTicketFile();
        if (await ticketFile.exists()) {
          _currentIdentity!.moonServerTicket =
              (await ticketFile.readAsString()).trim();
        }
      }
    } catch (e) {
      // Never silently turn the user into "identity-less": quarantine the
      // corrupt file so createIdentity cannot overwrite the only copy of the
      // secret key. Recovery means restoring from that quarantine / the vault.
      try {
        final file = await _getFile();
        if (await file.exists()) {
          final q =
              '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
          await file.rename(q);
          debugPrint('identity.json unreadable, quarantined to $q: $e');
        }
      } catch (_) {}
      _currentIdentity = null;
    }
  }

  Future<UserIdentity> createIdentity(String nickname,
      {String? serverAddress, String? moonServerTicket}) async {
    final sk = SecretKey.generate();
    final skBytes = sk.toBytes();
    final pk = sk.publicKey;
    final pkBytes = pk.asBytes();

    _currentIdentity = UserIdentity(
      secretKeyHex: _hexEncode(skBytes),
      publicKeyHex: _hexEncode(pkBytes),
      nickname: nickname,
      serverAddress: serverAddress,
      moonServerTicket: moonServerTicket,
    );

    await _save();
    return _currentIdentity!;
  }

  static String _hexEncode(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> updateShortId(String shortId) async {
    if (_currentIdentity != null) {
      _currentIdentity!.shortId = shortId;
      await _save();
    }
  }

  Future<void> updateNickname(String nickname) async {
    if (_currentIdentity != null) {
      _currentIdentity!.nickname = nickname;
      await _save();
    }
  }

  Future<void> updateServerAddress(String address) async {
    if (_currentIdentity != null) {
      _currentIdentity!.serverAddress = address;
      await _save();
    }
  }

  Future<void> updateMoonServerTicket(String ticket) async {
    if (_currentIdentity != null) {
      _currentIdentity!.moonServerTicket = ticket;
      await _save();
      final file = await _getMoonTicketFile();
      await file.writeAsString(ticket);
    }
  }

  Future<void> _save() async {
    final file = await _getFile();
    // Write to a temp file first, then swap, so a crash mid-write never leaves
    // identity.json half-written (Windows can't rename onto an existing file,
    // so the old one is removed first; the .tmp is recovered on initialize).
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_currentIdentity!.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }

  Future<void> clearIdentity() async {
    _currentIdentity = null;
    final file = await _getFile();
    if (await file.exists()) {
      await file.delete();
    }
    final tmp = File('${file.path}.tmp');
    if (await tmp.exists()) {
      await tmp.delete();
    }
  }

  /// Overwrites the local identity (e.g. after restoring it from the email
  /// vault on a fresh device) and persists both identity.json and the Moon
  /// ticket sidecar.
  Future<void> restoreIdentity(UserIdentity identity) async {
    _currentIdentity = identity;
    await _save();
    if (identity.moonServerTicket != null) {
      final ticketFile = await _getMoonTicketFile();
      await ticketFile.writeAsString(identity.moonServerTicket!);
    }
  }
}
