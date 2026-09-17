import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Surfaces incoming Wave messages as system notifications while the app UI
/// is not in the foreground.
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Whether the app UI is currently in the background. Updated by the app
  /// lifecycle observer; when true, incoming messages are posted as
  /// notifications instead of only landing in the chat list.
  bool appInBackground = false;

  static const _messageChannelId = 'wave_messages';
  static const _messageChannelName = 'Messages';
  static const _messageChannelDescription = 'Incoming Wave messages';

  bool _initialized = false;

  /// Becomes true when the Android 13+ notification permission was requested at
  /// least once but denied, so UI can explain why notifications stay silent.
  bool permissionDenied = false;

  /// Monotonic id generator: two messages arriving in the same millisecond
  /// would collide under a pure timestamp id and the later one would silently
  /// replace the earlier one's notification.
  static int _idSeed = 0;
  int _nextNotificationId() {
    _idSeed = (_idSeed + 1) & 0x7fffffff;
    return (DateTime.now().millisecondsSinceEpoch ^ _idSeed) & 0x7fffffff;
  }

  Future<void> init() async {
    if (_initialized || !Platform.isAndroid) return;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _plugin.initialize(settings: settings);
      _initialized = true;
      await requestPermission();
    } catch (_) {}
  }

  Future<bool> get hasPermission async {
    if (!Platform.isAndroid || !_initialized) return false;
    try {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin>()
              ?.areNotificationsEnabled() ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// (Re)prompts for the Android 13+ notification permission. Returns whether
  /// notifications are enabled afterwards; a denial is surfaced via
  /// [permissionDenied] so callers can hint at why messages stay silent.
  Future<bool> requestPermission() async {
    if (!Platform.isAndroid || !_initialized) return false;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      final granted = await hasPermission;
      if (!granted) {
        permissionDenied = true;
      }
      return granted;
    } catch (_) {
      return false;
    }
  }

  Future<void> showIncomingMessage({
    required String title,
    required String body,
  }) async {
    if (!_initialized || !appInBackground) return;
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          _messageChannelId,
          _messageChannelName,
          channelDescription: _messageChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
        ),
      );
      await _plugin.show(
        id: _nextNotificationId(),
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (_) {}
  }
}