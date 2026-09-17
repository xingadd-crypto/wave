import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_wave/theme/app_theme.dart';
import 'package:flutter_wave/providers/app_provider.dart';
import 'package:flutter_wave/screens/home_screen.dart';
import 'package:flutter_wave/services/iroh_service.dart';
import 'package:flutter_wave/screens/email_restore_screen.dart';
import 'package:flutter_wave/config.dart';

class RegistrationScreen extends ConsumerStatefulWidget {
  const RegistrationScreen({super.key});

  @override
  ConsumerState<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends ConsumerState<RegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nicknameController = TextEditingController();
  bool _isLoading = false;
  String _statusText = '';

  @override
  void initState() {
    super.initState();
    final iroh = IrohService();
    final identity = iroh.currentIdentity;
    if (identity != null) {
      _nicknameController.text = identity.nickname;
    }
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _statusText = 'Creating identity...';
    });

    try {
      final appStateNotifier = ref.read(appStateProvider.notifier);

      if (mounted) setState(() => _statusText = 'Creating identity...');
      await appStateNotifier.register(
        _nicknameController.text,
        moonServerId,
      );

      if (!mounted) return;
      setState(() => _statusText = 'Connecting...');

      final connected = await appStateNotifier.connectToServer();
      if (!mounted) return;
      if (connected) {
        final appState = ref.read(appStateProvider);
        setState(() => _statusText = 'Registered! Short ID: #${appState.shortId ?? "..."}');
      } else {
        setState(() => _statusText = 'Server offline, identity saved. You can retry from Settings.');
      }

      await Future.delayed(const Duration(seconds: 2));

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusText = 'Error: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(
                    Icons.waves,
                    size: 40,
                    color: AppTheme.primaryColor,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Welcome to Wave',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Set up your profile to start chatting',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 48),
                TextFormField(
                  controller: _nicknameController,
                  decoration: const InputDecoration(
                    labelText: 'Nickname',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a nickname';
                    }
                    if (value.length < 2) {
                      return 'Nickname must be at least 2 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 32),
                if (_statusText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _statusText,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _statusText.startsWith('Error')
                            ? AppTheme.errorColor
                            : AppTheme.textSecondary,
                      ),
                    ),
                  ),
                ElevatedButton(
                  onPressed: _isLoading ? null : _register,
                  child: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Text('Get Started'),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _isLoading
                      ? null
                      : () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const EmailRestoreScreen(),
                            ),
                          );
                        },
                  icon: const Icon(Icons.settings_backup_restore, size: 18),
                  label: const Text('Restore from my email backup'),
                ),
                const Spacer(),
                Text(
                  'By continuing, you agree to our Terms of Service',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textHint,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
