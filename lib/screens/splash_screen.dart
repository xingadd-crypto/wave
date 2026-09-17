import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_wave/theme/app_theme.dart';
import 'package:flutter_wave/providers/app_provider.dart';
import 'package:flutter_wave/screens/registration_screen.dart';
import 'package:flutter_wave/screens/home_screen.dart';
import 'package:flutter_wave/services/email_vault_service.dart';
import 'package:flutter_wave/services/identity_manager.dart';
import 'package:flutter_wave/services/iroh_service.dart';

class SplashScreen extends ConsumerStatefulWidget {
  final bool irohReady;
  const SplashScreen({super.key, required this.irohReady});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  String _statusText = 'Initializing...';
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );
    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
    );
    _controller.forward();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      _setStatus('Loading identity...');

      final appStateNotifier = ref.read(appStateProvider.notifier);

      if (!widget.irohReady) {
        _setStatus('Warning: iroh native library failed to load.\nRunning in offline mode...');
        await Future.delayed(const Duration(seconds: 2));
      }

      await appStateNotifier.initialize().timeout(const Duration(seconds: 10));
      await ref.read(friendsProvider.notifier).initialize();
      unawaited(_startupEmailVaultSync());

      final appState = ref.read(appStateProvider);

      if (!appState.isInitialized) {
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const RegistrationScreen()),
          );
        }
        return;
      }

      _setStatus('Connecting to Moon server...');

      bool connected = false;
      try {
        connected = await appStateNotifier.connectToServer()
            .timeout(const Duration(seconds: 6));
      } catch (_) {
        connected = false;
      }
      if (connected) {
        final identity = appStateNotifier.irohService.currentIdentity;
        _setStatus('Registered! Short ID: #${identity?.shortId ?? "..."}');
      } else {
        _setStatus('Server offline, running in offline mode');
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
          _isInitializing = false;
        });
      }
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const RegistrationScreen()),
        );
      }
    }
  }

  /// Mounted-guarded status update across the async shutdown steps.
  void _setStatus(String text) {
    if (!mounted) return;
    setState(() => _statusText = text);
  }

  /// Silent background restore on startup: pulls the newest vault mail, merges
  /// friends, and — on a fresh install with no local identity — adopts the
  /// cloud key pair so login is seamless. Never blocks the splash transition.
  Future<void> _startupEmailVaultSync() async {
    final svc = EmailVaultService.instance;
    await svc.initialize();
    if (!svc.isSyncReady || !mounted) return;
    final iroh = IrohService();
    final hasLocalIdentity = iroh.identityManager.hasIdentity;
    final friendsNotifier = ref.read(friendsProvider.notifier);
    final result = await svc.syncNow(
      localFriends: List.of(ref.read(friendsProvider)),
      localIdentity: hasLocalIdentity
          ? iroh.identityManager.currentIdentity?.toJson()
          : null,
    );
    if (!result.isOk || !mounted) return;
    if (result.mergedFriends != null) {
      friendsNotifier.applySyncedFriends(result.mergedFriends!);
    }
    if (!hasLocalIdentity && result.cloudIdentity != null) {
      await iroh.identityManager.restoreIdentity(
        UserIdentity.fromJson(result.cloudIdentity!),
      );
      final notifier = ref.read(appStateProvider.notifier);
      await notifier.initialize();
      await notifier.connectToServer();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = Image.asset(
      'assets/app_logo.png',
      fit: BoxFit.contain,
    );
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppTheme.primaryColor, AppTheme.secondaryColor],
          ),
        ),
        child: Center(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: ScaleTransition(
              scale: _scaleAnimation,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: FractionallySizedBox(
                      widthFactor: 0.9,
                      heightFactor: 0.9,
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: img,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Wave', style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(height: 4),
                  Text('P2P Instant Messenger', style: TextStyle(fontSize: 16, color: Colors.white.withValues(alpha: 0.9))),
                  const SizedBox(height: 32),
                  Text(_statusText, style: const TextStyle(fontSize: 14, color: Colors.white), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  if (_isInitializing)
                    const CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Colors.white)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
