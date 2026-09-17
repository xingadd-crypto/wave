import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_wave/models/friend.dart';
import 'package:flutter_wave/services/email_vault_crypto.dart';

/// Presets for common mailbox providers. All use implicit TLS (port 465 for
/// SMTP, 993 for IMAP), which [enough_mail] supports out of the box.
class EmailVaultProviderPreset {
  final String name;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;

  const EmailVaultProviderPreset({
    required this.name,
    required this.imapHost,
    required this.smtpHost,
    this.imapPort = 993,
    this.smtpPort = 465,
  });

  static const presets = <EmailVaultProviderPreset>[
    EmailVaultProviderPreset(
      name: 'QQ Mail',
      imapHost: 'imap.qq.com',
      smtpHost: 'smtp.qq.com',
    ),
    EmailVaultProviderPreset(
      name: '163 Mail',
      imapHost: 'imap.163.com',
      smtpHost: 'smtp.163.com',
    ),
    EmailVaultProviderPreset(
      name: 'Gmail',
      imapHost: 'imap.gmail.com',
      smtpHost: 'smtp.gmail.com',
    ),
    EmailVaultProviderPreset(
      name: 'Outlook',
      imapHost: 'imap-mail.outlook.com',
      smtpHost: 'smtp-mail.outlook.com',
    ),
  ];

  EmailVaultConfig toConfig({
    required String email,
    required String password,
  }) =>
      EmailVaultConfig(
        email: email,
        password: password,
        imapHost: imapHost,
        imapPort: imapPort,
        smtpHost: smtpHost,
        smtpPort: smtpPort,
        providerName: name,
      );
}

/// Connection settings for one mailbox, including its (in-memory) password.
class EmailVaultConfig {
  final String email;
  final String password;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;
  final String providerName;

  EmailVaultConfig({
    required this.email,
    required this.password,
    required this.imapHost,
    required this.imapPort,
    required this.smtpHost,
    required this.smtpPort,
    this.providerName = 'Custom',
  });

  EmailVaultConfig copyWithSensitive({String? password}) => EmailVaultConfig(
    email: email,
    password: password ?? this.password,
    imapHost: imapHost,
    imapPort: imapPort,
    smtpHost: smtpHost,
    smtpPort: smtpPort,
    providerName: providerName,
  );
}

/// Result of a vault push/pull/merge cycle.
class VaultSyncResult {
  final String? error;
  final bool pulled;
  final bool pushed;
  final bool mergedChanged;
  final int revision;

  /// Post-merge friend list when [mergedChanged] is true. The caller should
  /// persist it and update the UI.
  final List<Friend>? mergedFriends;

  /// Identity carried by the newest cloud vault. The caller decides whether to
  /// restore it (e.g. when this device has none yet).
  final Map<String, dynamic>? cloudIdentity;

  VaultSyncResult({
    this.error,
    this.pulled = false,
    this.pushed = false,
    this.mergedChanged = false,
    this.revision = 0,
    this.mergedFriends,
    this.cloudIdentity,
  });

  bool get isOk => error == null;
}

/// E2E-encrypted identity + friend backup stored inside the user's own
/// mailbox. The provider only ever sees the ciphertext blob ("Wave Vault"
/// subject, self-addressed). Push via SMTP, pull via IMAP search.
class EmailVaultService {
  EmailVaultService._();

  static final EmailVaultService instance = EmailVaultService._();

  static const int kVaultKeepMails = 3;

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  EmailVaultConfig? _config;
  List<int>? _cachedVaultKey;
  int _localRevision = 0;
  Map<String, int> _revisionsByEmail = {};
  bool _initialized = false;
  Timer? _autoPushTimer;
  Map<String, dynamic>? _pendingIdentity;
  List<Friend>? _pendingFriends;

  bool get isConfigured => _config != null;
  bool get hasCachedVaultKey => _cachedVaultKey != null;
  String? get configuredEmail => _config?.email;
  String? get providerName => _config?.providerName;
  int get localRevision => _localRevision;
  String? get connectionImapHost => _config?.imapHost;
  int get connectionImapPort => _config?.imapPort ?? 993;
  String? get connectionSmtpHost => _config?.smtpHost;
  int get connectionSmtpPort => _config?.smtpPort ?? 465;

  /// No-op diagnostic hook (everything is paired with real error return paths
  /// so the release build keeps no disk-logging).
  static void _logVault(String line) {}

  /// Ready to sync (configured with a usable cached key).
  bool get isSyncReady => isConfigured && hasCachedVaultKey;

  /// Drops the in-memory vault key. Use after a probe/sync reported backups
  /// that cannot be decrypted with the current password, so a later push is
  /// refused too instead of silently reusing the stale key.
  void clearVaultKeyCache() {
    _cachedVaultKey = null;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final credsJson = await _storage.read(
        key: _kCredentialsKey,
        iOptions: _iosOptions,
      );
      if (credsJson != null && credsJson.isNotEmpty) {
        final map =
            jsonDecode(credsJson) as Map<String, dynamic>;
        _config = _canonical(EmailVaultConfig(
          email: map['email'] as String? ?? '',
          password: map['password'] as String? ?? '',
          imapHost: map['imapHost'] as String? ?? '',
          imapPort: map['imapPort'] as int? ?? 993,
          smtpHost: map['smtpHost'] as String? ?? '',
          smtpPort: map['smtpPort'] as int? ?? 465,
          providerName: map['providerName'] as String? ?? 'Custom',
        ));
      }
      final stateJson = await _storage.read(key: _kStateKey);
      if (stateJson != null && stateJson.isNotEmpty) {
        final state = jsonDecode(stateJson) as Map<String, dynamic>;
        final revMap = state['revisions'];
        if (revMap is Map) {
          _revisionsByEmail = {
            for (final e in revMap.entries)
              if (e.value is num) e.key.toString(): (e.value as num).toInt(),
          };
        } else {
          // Legacy shape: a single revision for one (unknown) account. Adopt
          // it only when we actually know which account is configured.
          final legacy = state['revision'] as int? ?? 0;
          if (legacy > 0 && _config != null) {
            _revisionsByEmail = {_config!.email: legacy};
          }
        }
      }
      // The loaded revision is scoped to the configured account, so switching
      // mailboxes never inherits another mailbox's revision counter.
      _localRevision =
          _config != null ? _revisionsByEmail[_config!.email] ?? 0 : 0;
    } catch (_) {
      _config = null;
    }
    _initialized = true;
  }

  /// Derives the vault key from the user-defined custom encryption password.
/// The key lives in memory only and is never persisted; [initialize] cannot
/// recover it, so the user must re-provide the password after an app restart.
/// Call after [initialize] when the user re-enters their vault password.
  Future<void> bindVaultPassword(String vaultPassword) async {
    final config = _requireConfig();
    _cachedVaultKey = await EmailVaultCrypto.deriveVaultKey(
      vaultPassword,
      config.email,
    );
  }

  /// Re-derives a key from [vaultPassword] and checks it matches the cached
  /// vault key. Returns false when no key is cached or the passwords differ.
  Future<bool> verifyVaultPassword(String vaultPassword) async {
    final cached = _cachedVaultKey;
    if (cached == null) return false;
    final derived = await EmailVaultCrypto.deriveVaultKey(
      vaultPassword,
      _requireConfig().email,
    );
    if (derived.length != cached.length) return false;
    var match = true;
    for (var i = 0; i < derived.length; i++) {
      if (derived[i] != cached[i]) match = false;
    }
    return match;
  }

  /// Stores credentials and derives the vault encryption key from the
  /// user-defined [vaultPassword] (NOT the mailbox password). The derived key
  /// is kept in memory only and never persisted. The mailbox [password] is used
  /// only for IMAP/SMTP login and is saved so the app can still connect after a
  /// fresh install (Keychain/Keystore survives uninstalls on iOS, not Android).
  Future<void> saveCredentials(
    EmailVaultConfig config, {
    required String password,
    required String vaultPassword,
  }) async {
    _logVault(
      'saveCredentials: email=${config.email} imap=${config.imapHost}:'
      '${config.imapPort} smtp=${config.smtpHost}:${config.smtpPort}',
    );
    final vaultKey = await EmailVaultCrypto.deriveVaultKey(
      vaultPassword,
      config.email,
    );
    _config = _canonical(config).copyWithSensitive(password: password);
    _cachedVaultKey = vaultKey;
    _localRevision = _revisionsByEmail[_config!.email] ?? 0;
    await _persistCredentials();
    _logVault('saveCredentials: stored + key cached');
  }

  /// Updates only the IMAP/SMTP mailbox password. The in-memory vault
  /// encryption key is untouched, so a mailbox password / authorization code
  /// change does not invalidate the encrypted backup.
  Future<void> updateMailboxPassword(
    EmailVaultConfig config, {
    required String password,
  }) async {
    _logVault(
      'updateMailboxPassword: email=${config.email} imap=${config.imapHost}:'
      '${config.imapPort} smtp=${config.smtpHost}:${config.smtpPort}',
    );
    _requireVaultKey();
    _config = _canonical(config).copyWithSensitive(password: password);
    _localRevision = _revisionsByEmail[_config!.email] ?? 0;
    await _persistCredentials();
    _logVault('updateMailboxPassword: stored');
  }

  /// Mailbox addresses are case-insensitive; keep the stored copy canonical so
  /// the vault key, verifier and ownership checks never trip on case.
  static EmailVaultConfig _canonical(EmailVaultConfig c) {
    final canonicalEmail = c.email.trim().toLowerCase();
    if (canonicalEmail == c.email) return c;
    return EmailVaultConfig(
      email: canonicalEmail,
      password: c.password,
      imapHost: c.imapHost,
      imapPort: c.imapPort,
      smtpHost: c.smtpHost,
      smtpPort: c.smtpPort,
      providerName: c.providerName,
    );
  }

  Future<void> _persistCredentials() async {
    final cfg = _requireConfig();
    final credsJson = jsonEncode({
      'email': cfg.email,
      'password': cfg.password,
      'imapHost': cfg.imapHost,
      'imapPort': cfg.imapPort,
      'smtpHost': cfg.smtpHost,
      'smtpPort': cfg.smtpPort,
      'providerName': cfg.providerName,
    });
    await _storage.write(key: _kCredentialsKey, value: credsJson);
  }

  Future<void> clearCredentials() async {
    _config = null;
    _cachedVaultKey = null;
    _localRevision = 0;
    _revisionsByEmail = {};
    _autoPushTimer?.cancel();
    _autoPushTimer = null;
    await _storage.delete(key: _kCredentialsKey, iOptions: _iosOptions);
    await _storage.delete(key: _kStateKey);
  }

  /// Verifies the given settings work (SMTP login + send readiness and IMAP
  /// login). Returns null on success, or a human readable error message.
  Future<String?> testConnection(EmailVaultConfig config) async {
    _logVault(
      'testConnection: ${config.email} via ${config.imapHost}:'
      '${config.imapPort}/${config.smtpHost}:${config.smtpPort}',
    );
    try {
      final smtp = SmtpClient(
        _domainOf(config.email),
        isLogEnabled: false,
      );
      try {
        await smtp.connectToServer(
          config.smtpHost,
          config.smtpPort,
          isSecure: true,
        );
        await smtp.ehlo();
        await _authenticateSmtp(smtp, config.email, config.password);
        _logVault('testConnection: SMTP ok');
      } finally {
        if (smtp.isConnected) {
          try {
            await smtp.quit();
          } catch (_) {}
        }
      }

      final imap = ImapClient(isLogEnabled: false);
      try {
        await imap.connectToServer(
          config.imapHost,
          config.imapPort,
          isSecure: true,
        );
        await imap.login(config.email, config.password);
        await imap.selectInbox();
        _logVault('testConnection: IMAP ok');
      } finally {
        if (imap.isConnected) {
          try {
            await imap.logout();
          } catch (_) {}
        }
      }
      return null;
    } on ImapException catch (e) {
      _logVault('testConnection: IMAP error ${e.message ?? e}');
      return 'IMAP: ${e.message ?? e}';
    } on SmtpException catch (e) {
      return 'SMTP: ${e.message ?? e}';
    } catch (e) {
      return e.toString();
    }
  }

  /// Coalesced auto-push on local mutations. Fires 2 s after the last change.
  void scheduleAutoPush({
    Map<String, dynamic>? identity,
    required List<Friend> friends,
  }) {
    if (!isSyncReady) return;
    _pendingIdentity = identity;
    _pendingFriends = List.of(friends);
    _autoPushTimer?.cancel();
    _autoPushTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(pushPendingSnapshot()),
    );
  }

  Future<void> pushPendingSnapshot() async {
    if (_pendingFriends == null) {
      _autoPushTimer?.cancel();
      return;
    }
    final identity = _pendingIdentity;
    final friends = _pendingFriends!;
    _pendingFriends = null;
    _pendingIdentity = null;
    try {
      await pushVault(identity: identity, friends: friends);
    } catch (e) {
      // Auto-push runs unattended; a failure (e.g. the probe refusing to
      // overwrite a backup, or the network being down) must never be an
      // unhandled async error that kills the app. Re-queue once so the next
      // mutation retries, then give up silently.
      _logVault('pushPendingSnapshot: deferred: $e');
    }
  }

  /// Pushes the current snapshot. Increments the auto-invoicing local
  /// revision so it always wins over any stale cloud copy. Unless
  /// [verifyExisting] is disabled (callers that just verified the key against
  /// the cloud themselves), a pre-flight probe refuses to send when existing
  /// backups exist but none can be decrypted with the bound key — a mistyped
  /// encryption password must never overwrite the real backup with garbage.
  Future<void> pushVault({
    Map<String, dynamic>? identity,
    required List<Friend> friends,
    bool verifyExisting = true,
  }) async {
    final config = _requireConfig();
    final vaultKey = _requireVaultKey();
    if (verifyExisting) {
      final probe = await probeMailbox();
      if (probe != null && probe.found > 0 && probe.usable == 0) {
        _logVault('pushVault: refusing — existing backups undecryptable');
        throw EmailVaultException(
          'Found ${probe.found} existing backup mail(s) but none can be '
          'decrypted with the current encryption password. Refusing to '
          'overwrite your backup. Re-check the vault password, or push a '
          'fresh backup from your old device first.',
        );
      }
    }
    final revision = _nextRevision();
    final wire = await EmailVaultCrypto.buildAndEncrypt(
      email: config.email,
      revision: revision,
      updatedAt: DateTime.now().toUtc(),
      vaultKey: vaultKey,
      identity: identity,
      friends: friends,
    );

    final body = _chunkBase64(wire);
    final smtp = SmtpClient(_domainOf(config.email), isLogEnabled: false);
    try {
      await smtp.connectToServer(
        config.smtpHost,
        config.smtpPort,
        isSecure: true,
      );
      await smtp.ehlo();
      await _authenticateSmtp(smtp, config.email, config.password);
      final message =
          MessageBuilder()
            ..from = [MailAddress(config.email, config.email)]
            ..to = [MailAddress(config.email, config.email)]
            ..subject = kVaultSubject
            ..addHeader('X-Wave-Revision', revision.toString())
            ..text = body;
      final response = await smtp.sendMessage(message.buildMimeMessage());
      if (!response.isOkStatus) {
        throw EmailVaultException(
          'SMTP send failed: ${response.message ?? 'unknown error'}',
        );
      }
    } finally {
      if (smtp.isConnected) {
        try {
          await smtp.quit();
        } catch (_) {}
      }
    }
    _localRevision = revision;
    _revisionsByEmail[config.email] = revision;
    await _saveState();
    _logVault(
      'pushVault: ok rev=$revision friends=${friends.length} '
      'identity=${identity != null}',
    );
    // Clean up old vault mails, keep only the newest. Best effort: a hiccup
    // here (e.g. IMAP briefly unreachable) must not surface as a push failure.
    try {
      await cleanupOldMails(kVaultKeepMails);
    } catch (e) {
      _logVault('pushVault: cleanup skipped: $e');
    }
  }

  /// Full sync cycle used by both the settings screen and startup restore:
  /// pull newest vault -> merge friends (local note/name preferred) -> push the
  /// union back so the cloud converges. Exposes [VaultSyncResult.mergedFriends]
  /// and [VaultSyncResult.cloudIdentity] for the caller to apply.
  Future<VaultSyncResult> syncNow({
    required List<Friend> localFriends,
    Map<String, dynamic>? localIdentity,
  }) async {
    if (!isSyncReady) {
      return VaultSyncResult(error: 'Email vault is not configured');
    }
    try {
      _logVault(
        'syncNow: localFriends=${localFriends.length} localIdentity=${localIdentity != null}',
      );
      final cloud = await pullVault();
      if (cloud == null) {
        // A backup that exists but cannot be decrypted means the encryption
        // password (or mailbox authorization code) is wrong for this mailbox.
        // Refuse to push so a mistyped password can never overwrite the real
        // backup with garbage encrypted under the wrong key.
        final probe = await probeMailbox();
        if (probe != null && probe.found > 0 && probe.usable == 0) {
          _logVault('syncNow: cloud mails found but none decryptable, '
              'refusing to push');
          return VaultSyncResult(
            revision: _localRevision,
            error: 'Found ${probe.found} backup mail(s), but none can be '
                'decrypted with the current encryption password.',
          );
        }
        // Never overwrite a possibly-existing cloud backup with an empty
        // local vault (e.g. first-run restore): only push when the local side
        // actually has content.
        final hasLocalContent =
            localIdentity != null || localFriends.isNotEmpty;
        if (!hasLocalContent) {
          _logVault('syncNow: no cloud backup and no local content, '
              'skipping push');
          return VaultSyncResult(
            revision: _localRevision,
            cloudIdentity: null,
          );
        }
        await pushVault(
          identity: localIdentity,
          friends: localFriends,
          verifyExisting: false,
        );
        _logVault(
          'syncNow: no cloud backup, pushed local '
          'friends=${localFriends.length}',
        );
        return VaultSyncResult(
          revision: _localRevision,
          pushed: true,
          cloudIdentity: localIdentity,
        );
      }
      _logVault(
        'syncNow: cloud rev=${cloud.revision} friends=${cloud.friends?.length} '
        'identity=${cloud.identity != null}',
      );
      if (cloud.revision <= _localRevision && _localRevision > 0) {
        return VaultSyncResult(
          revision: _localRevision,
          pulled: true,
          cloudIdentity: cloud.identity,
        );
      }

      final merge = mergeFriends(localFriends, cloud.friends ?? const []);
      _localRevision = cloud.revision;
      _revisionsByEmail[_requireConfig().email] = cloud.revision;
      var pushed = false;
      List<Friend>? mergedFriends;
      if (merge.changed) {
        mergedFriends = merge.friends;
        await pushVault(
          identity: localIdentity ?? cloud.identity,
          friends: merge.friends,
          verifyExisting: false,
        );
        pushed = true;
      }
      await _saveState();
      _logVault(
        'syncNow: ok rev=$_localRevision pulled=true pushed=$pushed '
        'changed=${merge.changed} cloudIdentity=${cloud.identity != null}',
      );
      return VaultSyncResult(
        revision: _localRevision,
        pulled: true,
        pushed: pushed,
        mergedChanged: merge.changed,
        mergedFriends: mergedFriends,
        cloudIdentity: cloud.identity,
      );
    } on EmailVaultException catch (e) {
      _logVault('syncNow: vault error ${e.message}');
      return VaultSyncResult(
        revision: _localRevision,
        error: e.message,
      );
    } catch (e) {
      _logVault('syncNow: error $e');
      return VaultSyncResult(
        revision: _localRevision,
        error: e.toString(),
      );
    }
  }

  /// Downloads the newest vault mail, decrypts it and validates it against the
  /// mailbox address. Returns null when no usable vault exists yet.
  Future<VaultPayload?> pullVault() async {
    final config = _requireConfig();
    final vaultKey = _requireVaultKey();

    final imap = ImapClient(isLogEnabled: false);
    VaultPayload? best;
    var bestRevision = -1;
    try {
      await imap.connectToServer(
        config.imapHost,
        config.imapPort,
        isSecure: true,
      );
      await imap.login(config.email, config.password);
      await imap.selectInbox();
      final search = await imap.searchMessages(
        searchCriteria: 'HEADER Subject "$kVaultSubject"',
      );
      final sequence = search.matchingSequence;
      _logVault(
        'pullVault: search matched ${sequence?.length ?? 0} mail(s)',
      );
      if (sequence != null && sequence.isNotEmpty) {
        final fetched = await imap.fetchMessages(sequence, 'BODY.PEEK[]');
        var usable = 0;
        for (final message in fetched.messages) {
          final subject = message.decodeHeaderValue('Subject') ?? '';
          if (!subject.contains(kVaultSubject)) {
            _logVault(
              'pullVault: mail subject mismatch: "$subject"',
            );
            continue;
          }
          final body = message.decodeTextPlainPart();
          if (body == null || body.trim().isEmpty) {
            _logVault(
              'pullVault: mail "$subject": body empty ('
              'contentType=${message.decodeHeaderValue('Content-Type')})',
            );
            continue;
          }
          final wire = body
              .split(RegExp(r'\r?\n'))
              .where((line) => line.trim().isNotEmpty)
              .reduce((a, b) => a + b);
          _logVault(
            'pullVault: mail "$subject" bodyLen=${body.length} '
            'wireLen=${wire.length} wireHead=${wire.length > 16 ? wire.substring(0, 16) : wire}',
          );
          try {
            final decoded = await EmailVaultCrypto.decodeAndVerify(
              payloadBase64: wire,
              email: config.email,
              vaultKey: vaultKey,
            );
            usable++;
            if (decoded.payload.revision > bestRevision) {
              best = decoded.payload;
              bestRevision = decoded.payload.revision;
            }
          } on EmailVaultException catch (e) {
            _logVault('pullVault: mail "$subject" decode failed: ${e.message}');
          }
        }
        _logVault(
          'pullVault: fetched=${fetched.messages.length} usable=$usable '
          'bestRev=$bestRevision',
        );
      }
    } catch (e) {
      _logVault('pullVault: error $e');
      rethrow;
    } finally {
      if (imap.isConnected) {
        try {
          await imap.logout();
        } catch (_) {}
      }
    }
    return best;
  }

  /// Counts how many "Wave Vault" mails exist and how many of them can be
  /// decrypted with the currently cached key. Used by the restore screen to
  /// tell "no backup" apart from "backup exists but the authorization code
  /// (key) changed". Returns null when IMAP is unreachable.
  Future<({int found, int usable})?> probeMailbox() async {
    final config = _requireConfig();
    final vaultKey = _requireVaultKey();
    final imap = ImapClient(isLogEnabled: false);
    var found = 0;
    var usable = 0;
    try {
      await imap.connectToServer(
        config.imapHost,
        config.imapPort,
        isSecure: true,
      );
      await imap.login(config.email, config.password);
      await imap.selectInbox();
      final search = await imap.searchMessages(
        searchCriteria: 'HEADER Subject "$kVaultSubject"',
      );
      final sequence = search.matchingSequence;
      found = sequence?.length ?? 0;
      if (sequence != null && sequence.isNotEmpty) {
        final fetched = await imap.fetchMessages(sequence, 'BODY.PEEK[]');
        for (final message in fetched.messages) {
          final subject = message.decodeHeaderValue('Subject') ?? '';
          if (!subject.contains(kVaultSubject)) continue;
          final body = message.decodeTextPlainPart();
          if (body == null || body.trim().isEmpty) continue;
          final wire = body
              .split(RegExp(r'\r?\n'))
              .where((line) => line.trim().isNotEmpty)
              .reduce((a, b) => a + b);
          try {
            await EmailVaultCrypto.decodeAndVerify(
              payloadBase64: wire,
              email: config.email,
              vaultKey: vaultKey,
            );
            usable++;
          } on EmailVaultException {
            // count separately below
          }
        }
      }
      _logVault('probeMailbox: found=$found usable=$usable');
      return (found: found, usable: usable);
    } catch (e) {
      _logVault('probeMailbox: error $e');
      return null;
    } finally {
      if (imap.isConnected) {
        try {
          await imap.logout();
        } catch (_) {}
      }
    }
  }

  /// Deletes all vault mails except the newest [keepCN]. Returns the number of
  /// mails removed, or -1 when skipped (not configured).
  Future<int> cleanupOldMails([int keepCN = kVaultKeepMails]) async {
    if (!isSyncReady) return -1;
    final config = _requireConfig();
    final vaultKey = _requireVaultKey();

    final imap = ImapClient(isLogEnabled: false);
    final candidates = <(VaultPayload, int)>[];
    try {
      await imap.connectToServer(
        config.imapHost,
        config.imapPort,
        isSecure: true,
      );
      await imap.login(config.email, config.password);
      await imap.selectInbox();
      final search = await imap.searchMessages(
        searchCriteria: 'HEADER Subject "$kVaultSubject"',
      );
      final sequence = search.matchingSequence;
      if (sequence == null || sequence.isEmpty) return 0;
      final fetched = await imap.fetchMessages(sequence, '(UID BODY.PEEK[])');
      for (final message in fetched.messages) {
        final subject = message.decodeHeaderValue('Subject') ?? '';
        if (!subject.contains(kVaultSubject)) continue;
        final body = message.decodeTextPlainPart();
        if (body == null || body.trim().isEmpty) continue;
        final wire = body
            .split(RegExp(r'\r?\n'))
            .where((line) => line.trim().isNotEmpty)
            .reduce((a, b) => a + b);
        try {
          final decoded = await EmailVaultCrypto.decodeAndVerify(
            payloadBase64: wire,
            email: config.email,
            vaultKey: vaultKey,
          );
          candidates.add((decoded.payload, message.uid ?? -1));
        } on EmailVaultException {
          // Legacy/malformed payloads are removed as well.
          if (message.uid != null) {
            candidates.add((VaultPayload(
              version: 0,
              email: config.email,
              revision: -1,
              updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
            ), message.uid!));
          }
        }
      }
      // Decryptable payloads always beat legacy/undecryptable ones, so a pile
      // of old legacy mails can never push the newest readable backup into the
      // removal set. Within the same class the newest revision wins.
      candidates.sort((a, b) {
        final aDecyp = a.$1.version > 0 ? 0 : 1;
        final bDecyp = b.$1.version > 0 ? 0 : 1;
        if (aDecyp != bDecyp) return aDecyp.compareTo(bDecyp);
        return b.$1.revision.compareTo(a.$1.revision);
      });
      final keep = candidates.take(keepCN).toList();
      final remove = candidates.sublist(keep.length);
      if (remove.isNotEmpty) {
        final ids = remove.map((e) => e.$2).where((uid) => uid > 0).toList();
        if (ids.isNotEmpty) {
          final uidSequence = MessageSequence.fromIds(ids, isUid: true);
          await imap.uidStore(uidSequence, <String>['\\Deleted']);
          if (imap.serverInfo.supportsUidPlus) {
            // UID EXPUNGE removes only the messages in this UID range that are
            // marked \Deleted — i.e. exactly the vault mails we just flagged.
            await imap.uidExpunge(uidSequence);
          } else {
            // No UIDPLUS: never run a plain EXPUNGE, because that purges EVERY
            // message flagged \Deleted in the shared inbox (other users' or a
            // different session's mail could be among them). Leave the flags;
            // provider-side maintenance handles them.
            _logVault(
              'cleanupOldMails: no UIDPLUS, leaving \\Deleted flags in place',
            );
          }
        }
      }
      _logVault('cleanupOldMails: removed=${remove.length}');
      return remove.length;
    } finally {
      if (imap.isConnected) {
        try {
          await imap.logout();
        } catch (_) {}
      }
    }
  }

  Future<void> _authenticateSmtp(
    SmtpClient smtp,
    String username,
    String password,
  ) async {
    final mechanism = smtp.serverInfo.supportsAuth(AuthMechanism.plain)
        ? AuthMechanism.plain
        : AuthMechanism.login;
    if (!smtp.serverInfo.supportsAuth(mechanism)) {
      throw EmailVaultException('SMTP server does not support ${mechanism.name} auth');
    }
    await smtp.authenticate(username, password, mechanism);
  }

  int _nextRevision() {
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    return max(_localRevision + 1, nowMs);
  }

  Future<void> _saveState() async {
    await _storage.write(
      key: _kStateKey,
      value: jsonEncode({
        'revision': _revisionsByEmail[_config?.email ?? ''] ?? 0,
        'revisions': _revisionsByEmail,
        'lastSyncedAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  EmailVaultConfig _requireConfig() {
    final config = _config;
    if (config == null) {
      throw EmailVaultException('Email vault is not configured');
    }
    return config;
  }

  List<int> _requireVaultKey() {
    final key = _cachedVaultKey;
    if (key == null) {
      throw EmailVaultException('Password has not been bound to the vault');
    }
    return key;
  }

  static String _domainOf(String email) {
    final at = email.lastIndexOf('@');
    return at >= 0 ? email.substring(at + 1) : 'localhost';
  }

  /// Splits a base64 string into RFC 5322-safe lines (<= 72 chars). The
  /// receiver rejoins lines before decoding.
  static String _chunkBase64(String input, {int width = 72}) {
    if (input.length <= width) return input;
    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i += width) {
      final end = min(i + width, input.length);
      buffer.writeln(input.substring(i, end));
    }
    return buffer.toString().trimRight();
  }

  static const String _kCredentialsKey = 'email_vault/credentials';
  static const String _kStateKey = 'email_vault/state';

  static const IOSOptions _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );
}