import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_wave/providers/app_provider.dart';
import 'package:flutter_wave/screens/home_screen.dart';
import 'package:flutter_wave/theme/app_theme.dart';
import 'package:flutter_wave/services/email_vault_service.dart';
import 'package:flutter_wave/services/identity_manager.dart';
import 'package:flutter_wave/services/iroh_service.dart';

/// First-run onboarding for email vault restore: sign in with the same
/// mailbox used on a previous device and recover the identity key pair and
/// friend list. Never pushes a blank vault over the cloud copy.
class EmailRestoreScreen extends ConsumerStatefulWidget {
  const EmailRestoreScreen({super.key});

  @override
  ConsumerState<EmailRestoreScreen> createState() =>
      _EmailRestoreScreenState();
}

class _EmailRestoreScreenState extends ConsumerState<EmailRestoreScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _vaultPasswordController = TextEditingController();
  final _vaultPasswordConfirmController = TextEditingController();
  final _customImapController = TextEditingController();
  final _customSmtpController = TextEditingController();
  int _providerIndex = 0;
  bool _useCustom = false;
  bool _busy = false;
  String _status = '';

  EmailVaultService get _svc => EmailVaultService.instance;
  List<EmailVaultProviderPreset> get _presets =>
      EmailVaultProviderPreset.presets;

  @override
  void initState() {
    super.initState();
    EmailVaultService.instance.initialize();
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

  Future<void> _signInAndRestore() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final vaultPassword = _vaultPasswordController.text;
    final vaultConfirm = _vaultPasswordConfirmController.text;
    if (email.isEmpty || password.isEmpty || vaultPassword.isEmpty) {
      _setStatus(
          'Enter your email address, mailbox password and the encryption '
          'password used for the backup.');
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
      _setStatusInline('Connected. Verifying encryption password...');

      await _svc.saveCredentials(config,
          password: password, vaultPassword: vaultPassword);

      // Verify the encryption password can actually unlock an existing backup
      // before doing any merge, so a wrong password is reported clearly here.
      final verifyProbe = await _svc.probeMailbox();
      if (verifyProbe != null &&
          verifyProbe.found > 0 &&
          verifyProbe.usable == 0) {
        // Do not let the just-cached (wrong) key linger in memory, or a later
        // auto-push would keep being refused/corrupting under it.
        _svc.clearVaultKeyCache();
        _setStatusInline('Found ${verifyProbe.found} backup mail(s), but none can be '
            'decrypted with the encryption password you entered. Check the '
            'custom encryption password (it is NOT your mailbox password), '
            'then try again. If you forgot it, push a fresh backup from your '
            'old device first.');
        return;
      }
      _setStatusInline('Connected. Looking for your backup...');

      final result = await _svc.syncNow(
        localFriends: const [],
        localIdentity: null,
      );
      if (!result.isOk) {
        _setStatus('Restore failed: ${result.error}');
        return;
      }
      if (result.mergedFriends != null) {
        ref.read(friendsProvider.notifier)
            .applySyncedFriends(result.mergedFriends!);
      }

      final identityManager = IrohService().identityManager;
      final hasLocalIdentity = identityManager.hasIdentity;

      if (result.cloudIdentity == null) {
        final probe = await _svc.probeMailbox();
        if (probe != null && probe.found > 0 && probe.usable == 0) {
          _svc.clearVaultKeyCache();
          _setStatusInline('Found ${probe.found} backup mail(s), but none can be decrypted '
              'with the encryption password you entered. If you re-generated '
              'your QR/163 authorization code, the old backups also become '
              'unreadable. Sign in from your old device (or Email Sync '
              'settings) and push a fresh backup, then retry here.');
        } else {
          _setStatusInline('This mailbox has no backup yet. Create a new identity instead, '
              'or re-check your email address.');
        }
        return;
      }

      final notifier = ref.read(appStateProvider.notifier);
      if (!hasLocalIdentity) {
        await identityManager.restoreIdentity(
          UserIdentity.fromJson(result.cloudIdentity!),
        );
        await notifier.initialize();
        await notifier.connectToServer();
        _setStatusInline('Restored identity + friends. Entering Wave...');
      } else {
        // Local identity already present (e.g. a fresh registration). Merge
        // cloud friends only; keep the local key pair so existing chats work.
        await notifier.initialize();
        _setStatusInline('Friends merged from backup. Entering Wave...');
      }

      await Future.delayed(const Duration(seconds: 1));
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      _setStatus('Restore failed: $e');
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

  /// Sets [_status] without a snackbar, guarded against the screen being
  /// disposed during the awaited network calls.
  void _setStatusInline(String message) {
    if (!mounted) return;
    setState(() => _status = message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Restore from Email',
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
                Text(
                  'Restore my backup',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppTheme.primaryColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Sign in with the same mailbox you used on your other device '
                  'to recover your private key and friend list. The cloud copy '
                  'is always AES-GCM encrypted — only you can read it.',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  initialValue: _providerIndex,
                  decoration: const InputDecoration(
                    labelText: 'Mailbox provider',
                  ),
                  items: [
                    for (var i = 0; i < _presets.length; i++)
                      DropdownMenuItem(value: i, child: Text(_presets[i].name)),
                    const DropdownMenuItem(
                      value: 99,
                      child: Text('Custom server'),
                    ),
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
                    hintText:
                        'QQ/163: use IMAP authorization code, not login password',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _vaultPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Encryption password (custom)',
                    hintText:
                        'The encryption password used when the backup was made',
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
                  'Tip: Use your IMAP/SMTP authorization code, NOT your login '
                  'password.\n• QQ Mail: mail.qq.com → Settings → Account → '
                  'Enable IMAP → Generate authorization code',
                  style: TextStyle(color: AppTheme.textHint, fontSize: 11),
                ),
                const SizedBox(height: 16),
                if (_status.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _status,
                      style: TextStyle(
                        color: _status.startsWith('Restore failed') ||
                                _status.startsWith('Connection failed')
                            ? AppTheme.errorColor
                            : AppTheme.textSecondary,
                      ),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: _busy ? null : _signInAndRestore,
                  icon: const Icon(Icons.settings_backup_restore),
                  label: const Text('Sign in & Restore'),
                ),
              ],
            ),
    );
  }
}