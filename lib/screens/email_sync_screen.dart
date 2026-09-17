import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_wave/providers/app_provider.dart';
import 'package:flutter_wave/theme/app_theme.dart';
import 'package:flutter_wave/services/email_vault_service.dart';
import 'package:flutter_wave/services/identity_manager.dart';
import 'package:flutter_wave/services/iroh_service.dart';

/// Settings UI for the end-to-end encrypted email vault: backup the identity
/// key pair + friend list into the user's own mailbox and restore it on this
/// or a future device.
class EmailSyncScreen extends ConsumerStatefulWidget {
  const EmailSyncScreen({super.key});

  @override
  ConsumerState<EmailSyncScreen> createState() => _EmailSyncScreenState();
}

class _EmailSyncScreenState extends ConsumerState<EmailSyncScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _vaultPasswordController = TextEditingController();
  final TextEditingController _vaultPasswordConfirmController =
      TextEditingController();
  final TextEditingController _customImapController = TextEditingController();
  final TextEditingController _customSmtpController = TextEditingController();
  int _providerIndex = 0;
  bool _useCustom = false;
  bool _busy = false;
  String _status = '';
  String? _configuredEmail;

  EmailVaultService get _svc => EmailVaultService.instance;

  @override
  void initState() {
    super.initState();
    _configuredEmail = _svc.configuredEmail;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _vaultPasswordController.dispose();
    _vaultPasswordConfirmController.dispose();
    _customImapController.dispose();
    _customSmtpController.dispose();
    super.dispose();
  }

  bool get _isConfigured => _svc.isConfigured && _configuredEmail != null;

  List<EmailVaultProviderPreset> get _presets =>
      EmailVaultProviderPreset.presets;

  Future<void> _saveAndTest() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final vaultPassword = _vaultPasswordController.text;
    final vaultConfirm = _vaultPasswordConfirmController.text;
    if (email.isEmpty || password.isEmpty || vaultPassword.isEmpty) {
      _setStatus(
          'Enter your email address, mailbox password and an encryption password.');
      return;
    }
    if (vaultPassword != vaultConfirm) {
      _setStatus('The two encryption passwords do not match.');
      return;
    }
    setState(() => _busy = true);
    try {
      final config = _useCustom
          ? EmailVaultConfig(
              email: email,
              password: password,
              imapHost: _customImapController.text.trim(),
              imapPort: 993,
              smtpHost: _customSmtpController.text.trim(),
              smtpPort: 465,
              providerName: 'Custom',
            )
          : _presets[_providerIndex].toConfig(
              email: email,
              password: password,
            );

      final error = await _svc.testConnection(config);
      if (error != null) {
        _setStatus('Connection failed: $error');
        return;
      }
      await _svc.saveCredentials(config,
          password: password, vaultPassword: vaultPassword);
      if (mounted) setState(() => _configuredEmail = email);
      _setStatus('Connected. Pushing initial vault backup...');
      await _svc.pushVault(
        identity: _currentIdentityJson(),
        friends: ref.read(friendsProvider),
      );
      _setStatus('Backup complete. Your keys and friends are now protected.');
    } catch (e) {
      _setStatus('Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic>? _currentIdentityJson() =>
      IrohService().identityManager.currentIdentity?.toJson();

  /// Asks the user to re-enter their custom encryption password before an
  /// explicit sync/backup. Returns the entered password (or null on cancel).
  /// When a vault key is already cached the password is verified against it,
  /// and an incorrect password cancels the operation before anything is pushed
  /// with the wrong key.
  Future<bool> _verifyBeforeSync() async {
    final controller = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Verify encryption password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Re-enter the custom encryption password to confirm this '
              'sync/backup.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Encryption password',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Verify'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (entered == null || entered.isEmpty) return false;
    if (!_svc.hasCachedVaultKey) {
      await _svc.bindVaultPassword(entered);
      return true;
    }
    final ok = await _svc.verifyVaultPassword(entered);
    if (!ok) {
      _setStatus('Incorrect encryption password — sync cancelled.');
      return false;
    }
    return true;
  }

  Future<void> _syncNow() async {
    final verified = await _verifyBeforeSync();
    if (!verified) return;
    setState(() => _busy = true);
    try {
      final iroh = IrohService();
      final hasLocalIdentity = iroh.identityManager.hasIdentity;
      final result = await _svc.syncNow(
        localFriends: List.of(ref.read(friendsProvider)),
        localIdentity: hasLocalIdentity
            ? _currentIdentityJson()
            : null,
      );
      if (!result.isOk) {
        _setStatus('Sync failed: ${result.error}');
        return;
      }
      if (result.mergedFriends != null) {
        ref.read(friendsProvider.notifier).applySyncedFriends(result.mergedFriends!);
      }
      if (!hasLocalIdentity && result.cloudIdentity != null) {
        await iroh.identityManager.restoreIdentity(
          UserIdentity.fromJson(result.cloudIdentity!),
        );
        final notifier = ref.read(appStateProvider.notifier);
        await notifier.initialize();
        await notifier.connectToServer();
        _setStatus('New device restored: identity and friends synced.');
        return;
      }
      final parts = <String>[];
      if (result.pulled) parts.add('downloaded');
      if (result.pushed) parts.add('uploaded');
      if (result.mergedChanged) parts.add('friends merged');
      _setStatus(parts.isEmpty
          ? 'Already in sync.'
          : 'Sync ok (${parts.join(', ')}). Revision ${result.revision}.');
    } catch (e) {
      _setStatus('Sync failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pushNow() async {
    final verified = await _verifyBeforeSync();
    if (!verified) return;
    setState(() => _busy = true);
    try {
      await _svc.pushVault(
        identity: _currentIdentityJson(),
        friends: ref.read(friendsProvider),
      );
      _setStatus('Manual backup uploaded (revision ${_svc.localRevision}).');
    } catch (e) {
      _setStatus('Backup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cleanup() async {
    setState(() => _busy = true);
    try {
      final removed = await _svc.cleanupOldMails();
      _setStatus(
        removed > 0
            ? 'Old vault backups cleaned up ($removed removed).'
            : 'Nothing to clean up.',
      );
    } catch (e) {
      _setStatus('Cleanup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove email sync?'),
        content: Text(
          'The vault copy already in your mailbox is kept, but this app will '
          'stop syncing with $emailForDialog.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _svc.clearCredentials();
      if (mounted) setState(() => _configuredEmail = null);
      _status = '';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePassword() async {
    // Changing either password needs the vault key; after an app restart it is
    // only in memory, so ask the user to re-supply their encryption password.
    if (!_svc.hasCachedVaultKey) {
      final ok = await _verifyBeforeSync();
      if (!ok || !mounted) return;
    }
    final mailboxCtrl = TextEditingController();
    final vaultCtrl = TextEditingController();
    final result = await showDialog<_ChangedPasswords>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Change password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: mailboxCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New mailbox password / app password',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: vaultCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New encryption password (leave empty to keep)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              _ChangedPasswords(
                mailbox: mailboxCtrl.text,
                vault: vaultCtrl.text,
              ),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    mailboxCtrl.dispose();
    vaultCtrl.dispose();
    if (result == null || result.mailbox.isEmpty) return;
    setState(() => _busy = true);
    try {
      final config = EmailVaultConfig(
        email: _configuredEmail!,
        password: result.mailbox,
        imapHost: _svc.connectionImapHost ?? '',
        imapPort: _svc.connectionImapPort,
        smtpHost: _svc.connectionSmtpHost ?? '',
        smtpPort: _svc.connectionSmtpPort,
        providerName: _svc.providerName ?? 'Custom',
      );
      final error = await _svc.testConnection(config);
      if (error != null) {
        _setStatus('Connection with new password failed: $error');
        return;
      }
      if (result.vault.isEmpty) {
        // Changing only the mailbox password keeps the encryption untouched.
        await _svc.updateMailboxPassword(config, password: result.mailbox);
        _setStatus('Mailbox password updated.');
      } else {
        await _svc.saveCredentials(config,
            password: result.mailbox, vaultPassword: result.vault);
        // Push a fresh backup so the new encryption key also reaches the mail.
        await _svc.pushVault(
          identity: _currentIdentityJson(),
          friends: ref.read(friendsProvider),
        );
        _setStatus('Passwords updated and backup re-encrypted.');
      }
    } catch (e) {
      _setStatus('Password update failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setStatus(String message) {
    if (!mounted) return;
    setState(() => _status = message);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String get emailForDialog => _configuredEmail ?? 'this mailbox';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Email Sync',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
        ),
      ),
      body: _busy
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Working...'),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_isConfigured) ..._buildConfiguredSection(),
                if (!_isConfigured) ..._buildSetupSection(),
                if (_status.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      _status,
                      style: const TextStyle(color: AppTheme.textSecondary),
                    ),
                  ),
                const SizedBox(height: 16),
                _buildInfoSection(),
              ],
            ),
    );
  }

  List<Widget> _buildSetupSection() {
    return [
      Text(
        'Back up your identity & friends',
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: AppTheme.primaryColor,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Wave never stores your account online. Your mailbox becomes an '
        'encrypted vault: your private key and friend list are AES-GCM '
        'encrypted before leaving this device, so only you can read them. '
        'Re-install or switch phones, then sign in with the same mailbox to '
        'restore everything.',
        style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<int>(
        initialValue: _providerIndex,
        decoration: const InputDecoration(labelText: 'Mailbox provider'),
        items: [
          for (var i = 0; i < _presets.length; i++)
            DropdownMenuItem(value: i, child: Text(_presets[i].name)),
          const DropdownMenuItem(value: 99, child: Text('Custom server')),
        ],
        onChanged: (value) {
          setState(() {
            _providerIndex = value ?? 0;
            _useCustom = value == 99;
          });
        },
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _emailController,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: 'Email address',
          hintText: 'you@example.com',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _passwordController,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'Password / authorization code',
          hintText: 'QQ/163: use IMAP authorization code, not login password',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _vaultPasswordController,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'Encryption password (custom)',
          hintText:
              'Used to encrypt the backup — it is NOT your mailbox password',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _vaultPasswordConfirmController,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'Confirm encryption password',
          hintText: 'Re-enter the encryption password',
        ),
      ),
      if (_useCustom) ...[
        const SizedBox(height: 12),
        TextField(
          controller: _customImapController,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Custom IMAP host (implicit TLS, port 993)',
            hintText: 'imap.example.com',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _customSmtpController,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Custom SMTP host (implicit TLS, port 465)',
            hintText: 'smtp.example.com',
          ),
        ),
      ],
      const SizedBox(height: 12),
      const Text(
        'Tip: Use your IMAP/SMTP authorization code, NOT your login password.\n'
        '• QQ Mail: mail.qq.com → Settings → Account → Enable IMAP → Generate authorization code\n'
        '• 163 Mail: mail.163.com → Settings → POP3/SMTP/IMAP → Enable IMAP → Generate authorization code\n'
        '• Gmail: myaccount.google.com → Security → App passwords\n'
        '• Outlook: account.microsoft.com → Security → App passwords',
        style: TextStyle(color: AppTheme.textHint, fontSize: 11),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _busy ? null : _saveAndTest,
        icon: const Icon(Icons.vpn_key),
        label: const Text('Save & Start Backup'),
      ),
    ];
  }

  List<Widget> _buildConfiguredSection() {
    return [
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.mark_email_read_outlined,
            color: AppTheme.successColor),
        title: const Text('Vault mailbox'),
        subtitle: Text(
          '$_configuredEmail\n(${_svc.providerName ?? 'Custom'} · '
          'revision ${_svc.localRevision})',
        ),
        trailing: TextButton(
          onPressed: _busy ? null : _changePassword,
          child: const Text('Change password'),
        ),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _busy ? null : _syncNow,
              icon: const Icon(Icons.sync),
              label: const Text('Sync Now'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _pushNow,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Backup'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _cleanup,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('Cleanup'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextButton.icon(
              onPressed: _busy ? null : _removeAccount,
              icon: const Icon(Icons.link_off),
              label: const Text('Remove account'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      const Text(
        'Auto-push: friends, notes and nicknames are uploaded ~2 s after a '
        'change, and a silent pull runs on every app start.',
        style: TextStyle(color: AppTheme.textHint, fontSize: 12),
      ),
    ];
  }

  Widget _buildInfoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        Text(
          'How it works',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: AppTheme.primaryColor,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '• Push: an email titled "Wave Vault" is sent to yourself over SMTP.\n'
          '• Pull: IMAP searches for the newest "Wave Vault" mail.\n'
          '• Encryption: your custom encryption password → PBKDF2 → HKDF → '
          'AES-256-GCM. The mailbox password is only used to log in; your '
          'mailbox only ever stores ciphertext.\n'
          '• Merging: friends are unioned; your local notes/names win on '
          'conflicts.\n'
          '• Chat history never leaves the device.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
      ],
    );
  }
}

/// Result of the change-password dialog: a new mailbox password (required)
/// and an optional new custom encryption password (empty = keep current).
class _ChangedPasswords {
  final String mailbox;
  final String vault;
  _ChangedPasswords({required this.mailbox, required this.vault});
}