import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps the Wave process alive on Android while the app is backgrounded so
/// the iroh connection can keep receiving messages, and drives the
/// "后台接收消息" setting.
class BackgroundService {
  BackgroundService._();

  static const _enabledKey = 'background_receive_enabled';

  /// Must be called once at startup (platform-gated to Android).
  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'wave_background',
        channelName: 'Wave Background',
        channelDescription: 'Keeps Wave connected in the background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
        showWhen: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        autoRunOnBoot: false,
        stopWithTask: true,
      ),
    );
  }

  static Future<bool> loadEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_enabledKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, enabled);
    } catch (_) {}
  }

  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  static Future<ServiceRequestResult> start() async {
    if (!Platform.isAndroid) {
      return ServiceRequestFailure(
        error: UnsupportedError('Background service is Android-only'),
      );
    }
    return FlutterForegroundTask.startService(
      notificationTitle: 'Wave',
      notificationText: 'Running in background, receiving messages',
      serviceTypes: const [ForegroundServiceTypes.dataSync],
    );
  }

  static Future<ServiceRequestResult> stop() async {
    if (!Platform.isAndroid) {
      return ServiceRequestFailure(
        error: UnsupportedError('Background service is Android-only'),
      );
    }
    return FlutterForegroundTask.stopService();
  }
}