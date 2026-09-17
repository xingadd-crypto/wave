import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_wave/models/friend.dart';

/// Vault wire-format version. Version 1 encrypted the payload with a key
/// derived from the mailbox password; version 2 (current) uses the
/// user-defined custom encryption password. Old v1 backups are intentionally
/// not readable and surface as "Unsupported vault version 1" during pull.
const int kVaultVersion = 2;
const int kPbkdf2Iterations = 600000;
const int kAesKeyBits = 256;
const int kNonceLength = 12;
const int kMacLength = 16;
const String kVaultHkdfInfo = 'wave-vault';
const String kVaultSubject = 'Wave Vault';
const String kVaultVerifierSalt = 'wave-vault-auth';

class EmailVaultException implements Exception {
  final String message;
  EmailVaultException(this.message);
  @override
  String toString() => message;
}

/// Decrypted payload carried inside a vault email. [identity] mirrors
/// identity.json (secret key included) and [friends] mirrors friends.json
/// minus transient state (online status, unread counts).
class VaultPayload {
  final int version;
  final String email;
  final int revision;
  final DateTime updatedAt;
  final Map<String, dynamic>? identity;
  final List<Friend>? friends;

  VaultPayload({
    required this.version,
    required this.email,
    required this.revision,
    required this.updatedAt,
    this.identity,
    this.friends,
  });

  factory VaultPayload.fromJson(Map<String, dynamic> json, {String? expectedEmail}) {
    final version = json['version'] as int? ?? 1;
    final email = (json['email'] as String? ?? '').trim().toLowerCase();
    if (expectedEmail != null &&
        email != expectedEmail.trim().toLowerCase()) {
      throw EmailVaultException('Vault does not belong to $expectedEmail');
    }
    return VaultPayload(
      version: version,
      email: email,
      revision: json['revision'] as int? ?? 0,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      identity: json['identity'] == null
          ? null
          : Map<String, dynamic>.from(json['identity'] as Map),
      friends: json['friends'] == null
          ? null
          : (json['friends'] as List).map((e) => friendFromJson(e)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'email': email,
    'revision': revision,
    'updatedAt': updatedAt.toIso8601String(),
    'identity': identity,
    'friends': friends?.map(friendToJson).toList(),
  };

  static Map<String, dynamic> friendToJson(Friend f) => {
    'id': f.id,
    'name': f.name,
    'shortId': f.shortId,
    'note': f.note,
    'status': f.status.index,
    'createdAt': f.createdAt.toIso8601String(),
    'lastMessage': f.lastMessage,
    'lastMessageTime': f.lastMessageTime?.toIso8601String(),
  };

  static Friend friendFromJson(dynamic e) {
    final map = e as Map;
    return Friend(
      id: map['id'],
      name: map['name'] ?? '',
      shortId: map['shortId'] ?? '',
      note: map['note'] ?? '',
      status: FriendStatus.values[(map['status'] as int? ?? 2).clamp(0, 2)],
      createdAt: DateTime.tryParse(map['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      lastMessage: map['lastMessage'],
      lastMessageTime: DateTime.tryParse(map['lastMessageTime'] as String? ?? ''),
    );
  }
}

class VaultDecodeResult {
  final VaultPayload payload;
  final String encryptedJson;
  VaultDecodeResult(this.payload, this.encryptedJson);
}

final class EmailVaultCrypto {
  EmailVaultCrypto._();

  static final Random _random = Random.secure();

  /// Mailbox addresses are case-insensitive per RFC; fold the local part and
  /// domain to lower case everywhere a vault is keyed so "User@Gmail.com" and
  /// "user@gmail.com" always address the same encrypted vault.
  static String _normEmail(String email) => email.trim().toLowerCase();

  /// masterKey = PBKDF2-HMAC-SHA256(password, salt=email, 600k iters, 256 bits)
  ///
  /// 600k iterations can take hundreds of milliseconds on slow devices, so the
  /// derivation runs inside an isolate to keep the UI thread responsive.
  /// Captures (password, normalized email) are sendable values and the returned
  /// [Uint8List] is transferred back across the isolate boundary.
  static Future<Uint8List> derivePasswordKey(String password, String email) {
    final normEmail = _normEmail(email);
    return Isolate.run(() async {
      final algorithm = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: kPbkdf2Iterations,
        bits: kAesKeyBits,
      );
      final key = await algorithm.deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: utf8.encode(normEmail),
      );
      return Uint8List.fromList(await key.extractBytes());
    });
  }

  /// vaultKey = HKDF-SHA256(expand 'wave-vault', 32 bytes) from masterKey
  static Future<Uint8List> expandVaultKey(List<int> passwordKey) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(passwordKey),
      nonce: utf8.encode(kVaultHkdfInfo),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  static Future<Uint8List> deriveVaultKey(
    String password,
    String email,
  ) async =>
      expandVaultKey(await derivePasswordKey(password, email));

  /// Auth verifier folded into each payload so a pull with the wrong password
  /// (or corrupted cache) fails loudly instead of silently merging garbage.
  static Future<String> verifierHex(List<int> vaultKey, String email) async {
    final hmac = Hmac.sha256();
    final mac = await hmac.calculateMac(
      utf8.encode('$kVaultVerifierSalt:${_normEmail(email)}'),
      secretKey: SecretKey(vaultKey),
    );
    return _hexEncode(mac.bytes);
  }

  static Future<bool> verifierMatches(
    List<int> vaultKey,
    String email,
    String expectedHex,
  ) async =>
      (await verifierHex(vaultKey, email)).toLowerCase() ==
      expectedHex.trim().toLowerCase();

  /// Wire format: base64( 0x01 || nonce(12) || tag(16) || ciphertext )
  static Future<String> encryptPayload(String json, List<int> vaultKey) async {
    final aes = AesGcm.with256bits();
    final nonce = _randomBytes(kNonceLength);
    final box = await aes.encrypt(
      utf8.encode(json),
      secretKey: SecretKey(vaultKey),
      nonce: nonce,
    );
    final out = Uint8List(1 + kNonceLength + kMacLength + box.cipherText.length);
    out[0] = kVaultVersion;
    out.setRange(1, 1 + kNonceLength, nonce);
    out.setRange(1 + kNonceLength, 1 + kNonceLength + kMacLength, box.mac.bytes);
    out.setRange(1 + kNonceLength + kMacLength, out.length, box.cipherText);
    return base64.encode(out);
  }

  static Future<String> decryptPayload(
    String payloadBase64,
    List<int> vaultKey,
  ) async {
    late final Uint8List bytes;
    try {
      bytes = base64.decode(payloadBase64.trim());
    } catch (_) {
      throw EmailVaultException('Vault payload is not valid base64');
    }
    if (bytes.length < 1 + kNonceLength + kMacLength) {
      throw EmailVaultException('Vault payload too short');
    }
    if (bytes[0] != kVaultVersion) {
      throw EmailVaultException('Unsupported vault version ${bytes[0]}');
    }
    final nonce = bytes.sublist(1, 1 + kNonceLength);
    final mac = bytes.sublist(1 + kNonceLength, 1 + kNonceLength + kMacLength);
    final cipher = bytes.sublist(1 + kNonceLength + kMacLength);
    final aes = AesGcm.with256bits();
    final box = SecretBox(cipher, nonce: nonce, mac: Mac(mac));
    try {
      final clear = await aes.decrypt(box, secretKey: SecretKey(vaultKey));
      return utf8.decode(clear);
    } on SecretBoxAuthenticationError {
      throw EmailVaultException('Wrong password or tampered vault payload');
    }
  }

  /// Encrypts + authenticates a full payload and returns the wire base64.
  static Future<String> buildAndEncrypt({
    required String email,
    required int revision,
    required DateTime updatedAt,
    required List<int> vaultKey,
    Map<String, dynamic>? identity,
    List<Friend>? friends,
  }) async {
    final verifier = await verifierHex(vaultKey, email);
    final json = jsonEncode({
      ...VaultPayload(
        version: kVaultVersion,
        email: email,
        revision: revision,
        updatedAt: updatedAt,
        identity: identity,
        friends: friends,
      ).toJson(),
      'verifier': verifier,
    });
    return encryptPayload(json, vaultKey);
  }

  /// Decrypts and validates a wire payload. Throws [EmailVaultException] on
  /// tampering, wrong password, or a vault that belongs to another mailbox.
  static Future<VaultDecodeResult> decodeAndVerify({
    required String payloadBase64,
    required String email,
    required List<int> vaultKey,
  }) async {
    final encryptedJson = await decryptPayload(payloadBase64, vaultKey);
    late final Map<String, dynamic> json;
    try {
      json = jsonDecode(encryptedJson) as Map<String, dynamic>;
    } catch (_) {
      throw EmailVaultException('Vault payload is corrupted');
    }
    final verifierHexValue = json['verifier'] as String?;
    if (verifierHexValue == null ||
        !await verifierMatches(vaultKey, email, verifierHexValue)) {
      throw EmailVaultException('Wrong password or invalid vault');
    }
    final payload = VaultPayload.fromJson(json, expectedEmail: email);
    return VaultDecodeResult(payload, encryptedJson);
  }

  static List<int> _randomBytes(int length) =>
      Uint8List.fromList(List<int>.generate(length, (_) => _random.nextInt(256)));

  static String _hexEncode(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class FriendMergeResult {
  final List<Friend> friends;
  final bool changed;
  final int added;
  FriendMergeResult(this.friends, this.changed, this.added);
}

/// Merges cloud friends into the local list. Rules:
///   * union by friend id;
///   * friends only on the cloud are appended (union);
///   * friends only on local are kept untouched;
///   * for duplicates, the local note/name win, shorter/empty cloud fields are
///     backfilled, statuses upgrade toward accepted, and last message info is
///     taken from whichever side is newer.
FriendMergeResult mergeFriends(List<Friend> local, List<Friend> cloud) {
  final locals = {for (final f in local) f.id: f};
  final merged = [
    for (final f in local) f,
  ];
  var changed = false;
  var added = 0;

  for (final cloudFriend in cloud) {
    final existing = locals[cloudFriend.id];
    if (existing == null) {
      merged.add(cloudFriend);
      changed = true;
      added++;
      continue;
    }
    final out = _mergeFriend(existing, cloudFriend);
    if (!_sameSyncedFriend(existing, out)) {
      changed = true;
      merged[merged.indexWhere((f) => f.id == existing.id)] = out;
    }
  }
  return FriendMergeResult(merged, changed, added);
}

Friend _mergeFriend(Friend local, Friend cloud) {
  final localTime = local.lastMessageTime;
  final cloudTime = cloud.lastMessageTime;
  final cloudNewer = cloudTime != null &&
      (localTime == null || cloudTime.isAfter(localTime));
  final localName = local.name.trim().isNotEmpty;
  final localShort = local.shortId.trim().isNotEmpty;
  final localNote = local.note.trim().isNotEmpty;
  final mustUpgradeStatus =
      local.status != FriendStatus.accepted && cloud.status == FriendStatus.accepted;

  String? lastMessage;
  DateTime? lastMessageTime;
  if (cloudNewer) {
    lastMessage = cloud.lastMessage ?? local.lastMessage;
    lastMessageTime = cloudTime;
  } else {
    lastMessage = local.lastMessage ?? cloud.lastMessage;
    lastMessageTime = localTime ?? cloudTime;
  }

  return local.copyWith(
    name: localName ? local.name : cloud.name,
    shortId: localShort ? local.shortId : cloud.shortId,
    note: localNote ? local.note : cloud.note,
    status: mustUpgradeStatus ? FriendStatus.accepted : local.status,
    lastMessage: lastMessage,
    lastMessageTime: lastMessageTime,
  );
}

bool _sameSyncedFriend(Friend a, Friend b) =>
    a.id == b.id &&
    a.name == b.name &&
    a.shortId == b.shortId &&
    a.note == b.note &&
    a.status == b.status &&
    a.createdAt.isAtSameMomentAs(b.createdAt) &&
    a.lastMessage == b.lastMessage &&
    _sameTime(a.lastMessageTime, b.lastMessageTime);

bool _sameTime(DateTime? a, DateTime? b) {
  if (a == null) return b == null;
  if (b == null) return false;
  return a.isAtSameMomentAs(b);
}