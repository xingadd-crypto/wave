import 'dart:convert';

import 'package:flutter_wave/models/friend.dart';
import 'package:flutter_wave/services/email_vault_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const email = 'alice@example.com';
  const password = 'correct horse battery staple';

  test('deriveVaultKey is deterministic per (password, email)', () async {
    final key1 = await EmailVaultCrypto.deriveVaultKey(password, email);
    final key2 = await EmailVaultCrypto.deriveVaultKey(password, email);
    final key3 =
        await EmailVaultCrypto.deriveVaultKey('other-password', email);
    expect(key1, key2);
    expect(key3, isNot(key1));
    expect(key1.length, 32);
  });

  test('build + decrypt round trip preserves payload', () async {
    final vaultKey = await EmailVaultCrypto.deriveVaultKey(password, email);
    final friends = [
      Friend(
        id: 'eid:a',
        name: 'Alice',
        shortId: 'abc123',
        note: 'colleague',
        status: FriendStatus.accepted,
        createdAt: DateTime(2026, 1, 2, 3, 4, 5),
        lastMessage: 'hi',
        lastMessageTime: DateTime(2026, 2, 3, 4, 5, 6),
      ),
    ];
    final wire = await EmailVaultCrypto.buildAndEncrypt(
      email: email,
      revision: 7,
      updatedAt: DateTime(2026, 9, 11),
      vaultKey: vaultKey,
      identity: {
        'publicKeyHex': 'pub',
        'nickname': 'Alice',
      },
      friends: friends,
    );
    final decoded =
        await EmailVaultCrypto.decodeAndVerify(
          payloadBase64: wire,
          email: email,
          vaultKey: vaultKey,
        );
    expect(decoded.payload.revision, 7);
    expect(decoded.payload.email, email);
    expect(decoded.payload.identity!['nickname'], 'Alice');
    expect(decoded.payload.friends!.single.id, 'eid:a');
    expect(decoded.payload.friends!.single.note, 'colleague');
    expect(decoded.payload.updatedAt, DateTime(2026, 9, 11));
  });

  test('wrong password fails verification', () async {
    final vaultKey = await EmailVaultCrypto.deriveVaultKey(password, email);
    final wire = await EmailVaultCrypto.buildAndEncrypt(
      email: email,
      revision: 1,
      updatedAt: DateTime(2026, 9, 11),
      vaultKey: vaultKey,
      friends: [],
    );
    final wrongKey =
        await EmailVaultCrypto.deriveVaultKey('wrong-password', email);
    expect(
      () => EmailVaultCrypto.decodeAndVerify(
        payloadBase64: wire,
        email: email,
        vaultKey: wrongKey,
      ),
      throwsA(isA<EmailVaultException>()),
    );
  });

  test('payload from another mailbox is rejected', () async {
    final vaultKeyA =
        await EmailVaultCrypto.deriveVaultKey(password, 'a@example.com');
    final vaultKeyShared =
        await EmailVaultCrypto.deriveVaultKey(password, email);
    final wire = await EmailVaultCrypto.buildAndEncrypt(
      email: 'a@example.com',
      revision: 1,
      updatedAt: DateTime(2026, 9, 11),
      vaultKey: vaultKeyA,
    );
    await expectLater(
      EmailVaultCrypto.decodeAndVerify(
        payloadBase64: wire,
        email: email,
        vaultKey: vaultKeyShared,
      ),
      throwsA(isA<EmailVaultException>()),
    );
  });

  test('tampered ciphertext is detected', () async {
    final vaultKey = await EmailVaultCrypto.deriveVaultKey(password, email);
    final wire = await EmailVaultCrypto.buildAndEncrypt(
      email: email,
      revision: 1,
      updatedAt: DateTime(2026, 9, 11),
      vaultKey: vaultKey,
      friends: [],
    );
    final bytes = base64Decode(wire);
    bytes[1] ^= 0x01;
    final tampered = base64Encode(bytes);
    await expectLater(
      EmailVaultCrypto.decodeAndVerify(
        payloadBase64: tampered,
        email: email,
        vaultKey: vaultKey,
      ),
      throwsA(isA<EmailVaultException>()),
    );
  });

  group('mergeFriends', () {
    Friend local({
      String id = 'eid:l',
      String name = 'Local',
      String shortId = '',
      String note = '',
      FriendStatus status = FriendStatus.accepted,
      DateTime? createdAt,
      String? lastMessage,
      DateTime? lastMessageTime,
    }) => Friend(
      id: id,
      name: name,
      shortId: shortId,
      note: note,
      status: status,
      createdAt: createdAt ?? DateTime(2026, 1, 1),
      lastMessage: lastMessage,
      lastMessageTime: lastMessageTime,
    );

    test('keeps both sides, prefers local note/name, upgrades status', () {
      final merged = mergeFriends([
        local(name: 'Alice', note: 'work', lastMessage: 'old'),
        local(id: 'eid:only-local', name: 'OnlyLocal'),
      ], [
        local(id: 'eid:l', name: '', shortId: 'short1'),
        local(id: 'eid:cloud', name: 'CloudFriend'),
      ]);
      final byId = {for (final f in merged.friends) f.id: f};
      expect(merged.added, 1);
      expect(merged.changed, isTrue);
      expect(byId['eid:l']!.name, 'Alice');
      expect(byId['eid:l']!.note, 'work');
      expect(byId['eid:l']!.shortId, 'short1');
      expect(byId.containsKey('eid:only-local'), isTrue);
      expect(byId.containsKey('eid:cloud'), isTrue);
    });

    test('local pending + cloud accepted upgrades to accepted', () {
      final localFriend = local(
        id: 'eid:x',
        status: FriendStatus.pendingOut,
      );
      final cloudFriend = local(
        id: 'eid:x',
        status: FriendStatus.accepted,
      );
      final merged = mergeFriends([localFriend], [cloudFriend]);
      expect(merged.friends.single.status, FriendStatus.accepted);
    });

    test('newer last message wins', () {
      final older = local(
        id: 'eid:m',
        lastMessage: 'older',
        lastMessageTime: DateTime(2026, 1, 1),
      );
      final newer = local(
        id: 'eid:m',
        lastMessage: 'newer',
        lastMessageTime: DateTime(2026, 2, 1),
      );
      expect(mergeFriends([older], [newer]).friends.single.lastMessage, 'newer');
      expect(mergeFriends([newer], [older]).friends.single.lastMessage, 'newer');
    });

    test('no changes when lists are identical', () {
      final friends = [local(name: 'Same')];
      final result = mergeFriends(friends, [local(name: 'Same')]);
      expect(result.changed, isFalse);
      expect(result.added, 0);
    });
  });
}