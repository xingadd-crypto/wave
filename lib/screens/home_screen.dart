import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_wave/providers/app_provider.dart';
import 'package:flutter_wave/screens/contacts_screen.dart';
import 'package:flutter_wave/screens/chat_list_screen.dart';
import 'package:flutter_wave/screens/moments_screen.dart';
import 'package:flutter_wave/screens/settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  int _currentIndex = 0;

  // Scene-aware presence heartbeat, not a greedy poll:
  //   - passive: any verified incoming stream marks the sender online immediately
  //     (onPeerSeen) at zero probe cost — this covers friends who contact us;
  //   - scene-aware: while foregrounded on Chats / Contacts a low-frequency tick
  //     (90 s) re-probes only "unresolved" friends. `probeFriendsPresence` caps
  //     the batch at 4 and backs off exponentially on failures, so the radio
  //     stays quiet. The timer is cancelled the moment the user leaves those
  //     tabs or backgrounds the app.
  //   - instant: switching into Chats / Contacts or resuming from background
  //     fires one immediate probe to refresh the snapshot.
  static const Duration _presenceTick = Duration(seconds: 90);
  Timer? _presenceTimer;
  bool _foreground = true;

  final List<Widget> _screens = [
    const ChatListScreen(),
    const ContactsScreen(),
    const MomentsScreen(),
    const SettingsScreen(),
  ];

  bool get _presenceSceneEnabled =>
      _foreground && (_currentIndex == 0 || _currentIndex == 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.read(friendsProvider.notifier).probePresence();
    _syncPresenceTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _presenceTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _foreground;
    _foreground = state == AppLifecycleState.resumed;
    // Coming back from background: refresh the snapshot right away instead of
    // waiting up to one tick.
    if (_foreground && !wasForeground) {
      ref.read(friendsProvider.notifier).probePresence();
    }
    _syncPresenceTimer();
  }

  void _syncPresenceTimer() {
    final enabled = _presenceSceneEnabled;
    if (enabled && _presenceTimer == null) {
      _presenceTimer = Timer.periodic(_presenceTick, (_) {
        ref.read(friendsProvider.notifier).probePresence();
      });
    } else if (!enabled && _presenceTimer != null) {
      _presenceTimer?.cancel();
      _presenceTimer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
          // Probe friends' P2P presence when the user is looking at a screen
          // that shows online/offline status (Chats / Contacts).
          if (index == 0 || index == 1) {
            ref.read(friendsProvider.notifier).probePresence();
          }
          _syncPresenceTimer();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Contacts',
          ),
          NavigationDestination(
            icon: Icon(Icons.public),
            selectedIcon: Icon(Icons.public),
            label: 'Moments',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}