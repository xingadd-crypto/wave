import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iroh_flutter/iroh_flutter.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_wave/theme/app_theme.dart';
import 'package:flutter_wave/providers/app_provider.dart';
import 'package:flutter_wave/models/friend.dart';
import 'package:flutter_wave/models/message.dart';
import 'package:flutter_wave/models/file_transfer.dart';
import 'package:flutter_wave/services/iroh_service.dart';
import 'package:flutter_wave/services/app_version.dart';
import 'package:flutter_wave/services/background_service.dart';
import 'package:flutter_wave/services/notification_service.dart';
import 'package:flutter_wave/services/persistence_service.dart';
import 'package:flutter_wave/services/update_service.dart';
import 'package:flutter_wave/screens/splash_screen.dart';
import 'package:flutter_wave/screens/call_screen.dart';
import 'package:flutter_wave/screens/chat_screen.dart';
import 'package:flutter_wave/screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterForegroundTask.initCommunicationPort();
  await NotificationService.instance.init();
  await BackgroundService.init();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };

  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Container(
      color: Colors.red,
      padding: const EdgeInsets.all(16),
      child: Text(
        'Error: ${details.exceptionAsString()}',
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Platform error: $error\n$stack');
    return true;
  };

  bool irohReady = false;
  try {
    await Iroh.init().timeout(const Duration(seconds: 15));
    irohReady = true;
  } catch (e) {
    debugPrint('Iroh.init() failed: $e');
  }

  runApp(
    ProviderScope(
      child: WaveApp(irohReady: irohReady),
    ),
  );
}

class WaveApp extends ConsumerStatefulWidget {
  final bool irohReady;
  const WaveApp({super.key, required this.irohReady});

  @override
  ConsumerState<WaveApp> createState() => _WaveAppState();
}

class _WaveAppState extends ConsumerState<WaveApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  NavigatorState? _fileOfferDialogNav;
  bool _callScreenOpen = false;
  Timer? _updateTimer;

  /// Subscriptions created by [_setupSync]. Held so a hot restart / rebuild of
  /// the root state cancels them instead of stacking duplicate listeners.
  final List<StreamSubscription<dynamic>> _syncSubscriptions = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupSync();
    _setupUpdateChecker();
    _restoreBackgroundService();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    for (final sub in _syncSubscriptions) {
      unawaited(sub.cancel());
    }
    _syncSubscriptions.clear();
    // Reset the singleton's function-pointers so a rebuilt root state does not
    // keep firing callbacks into a defunct `ref`.
    final iroh = IrohService();
    iroh.isAcceptedFriend = null;
    iroh.onPeerSeen = null;
    iroh.onFriendPresence = null;
    iroh.onOutboxResult = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // While the UI is not resumed (background / lock screen), incoming
    // messages are surfaced as system notifications.
    NotificationService.instance.appInBackground =
        state != AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _restoreBackgroundService();
    }
  }

  Future<void> _restoreBackgroundService() async {
    if (!await BackgroundService.loadEnabled()) return;
    if (await BackgroundService.isRunning) return;
    await BackgroundService.start();
  }

  // OTA update check: silent on startup (after the app settles) and every 24h
  // while running. Only active once a manifest URL is configured in Settings.
  // Prompts at most once per new version ("稍后" dismisses it until the next
  // release shows up).
void _setupUpdateChecker() {
    Future<void> check() async {
      if (!mounted) return;
      final nav = _navKey.currentState;
      if (nav == null) return;
      try {
        final result = await UpdateService.checkForUpdate();
        if (!mounted) return;
        if (!result.available || result.info == null) return;
        final lastSeen = await PersistenceService.loadLastSeenUpdateVersion();
        if (!mounted) return;
        if (lastSeen == result.info!.version) return;
        _showUpdatePrompt(nav, result.info!);
      } catch (_) {}
    }

    Timer(const Duration(seconds: 10), check);
    _updateTimer = Timer.periodic(UpdateService.autoCheckInterval, (_) => check());
  }

  void _showUpdatePrompt(NavigatorState nav, UpdateInfo info) {
    if (!mounted || info.version.isEmpty) return;
    showDialog<void>(
      context: nav.context,
      builder: (dialogContext) => AlertDialog(
        title: Text('发现新版本 v${info.version}'),
        content: Text(
          info.notes == null || info.notes!.trim().isEmpty
              ? '当前版本 v$appVersion，有可用的新版本。'
              : '当前版本 v$appVersion。\n\n更新内容：\n${info.notes}',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              // Capture the navigator before the await so a dismissible dialog
              // that is closed mid-persist still pops safely.
              final navigator = Navigator.of(dialogContext);
              await PersistenceService.saveUpdateSettings(
                lastSeenVersion: info.version,
              );
              navigator.pop();
            },
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              nav.push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
            child: const Text('查看更新'),
          ),
        ],
      ),
    );
  }

  // Persistent listeners that outlive any single screen. They must not live in a
  // widget that gets disposed (e.g. SplashScreen), otherwise incoming events
  // arriving later hit a disposed `ref`.
  void _setupSync() {
    final iroh = IrohService();

    // Presence probes from unknown/stranger peers must report offline. Only
    // accepted friends get an "online" reply (mirrors the CLI's friend check).
    iroh.isAcceptedFriend = (peerHex) {
      return ref
          .read(friendsProvider)
          .any((f) => f.id == peerHex && f.status == FriendStatus.accepted);
    };

    // Any verified traffic from a friend proves they are reachable right now.
    // With the periodic full-list poll gone, this is what keeps online state
    // fresh — at zero background probe cost for friends who contact us.
    iroh.onPeerSeen = (peerHex) {
      ref.read(friendsProvider.notifier).setFriendOnline(peerHex, true);
      unawaited(IrohService().notifyFriendOnline(peerHex));
    };

    // Presence replies carrying an app version refresh the friend's transient
    // version chip (1.0.27+ peers only; older peers simply never announce one).
    iroh.onFriendPresence = (peerHex, version, platform) {
      ref.read(friendsProvider.notifier).updateFriendVersion(peerHex, version ?? '',
          platform: platform);
    };

    // Flushed outbox messages surface as delivered in the chat UI.
    iroh.onOutboxResult = (friendId, messageId, delivered) {
      ref.read(messagesProvider(friendId).notifier).updateMessageStatus(
        messageId,
        delivered ? MessageStatus.delivered : MessageStatus.pending,
      );
    };

    _syncSubscriptions.add(iroh.friendRequestStream.listen((friend) {
      ref.read(friendsProvider.notifier).addFriend(friend);
    }));

    _syncSubscriptions.add(iroh.incomingMessageStream.listen((event) {
      final parts = event.split(':');
      if (parts.length < 2) return;
      final type = parts[0];
      final fromHex = parts[1];
      final friends = ref.read(friendsProvider);
      if (type == 'friend_accepted') {
        Friend? accepted;
        for (final f in friends) {
          if (f.id.toLowerCase() == fromHex.toLowerCase()) {
            final updated = f.copyWith(status: FriendStatus.accepted);
            ref.read(friendsProvider.notifier).updateFriend(updated);
            accepted = updated;
            break;
          }
        }
        // A friend request they accepted proves they are reachable right now.
        ref.read(friendsProvider.notifier).setFriendOnline(fromHex, true);
        unawaited(iroh.notifyFriendOnline(fromHex));
        // The peer accepted us but we have no matching entry (e.g. we added
        // them offline by public key and the pending-out entry was lost or
        // pruned). Surface them as an accepted friend anyway.
        if (accepted == null) {
          accepted = Friend(
            id: fromHex,
            name: 'Friend',
            shortId: '',
            status: FriendStatus.accepted,
            createdAt: DateTime.now(),
          );
          ref.read(friendsProvider.notifier).addFriend(accepted);
        }
        _offerChatAfterAccept(accepted);
      } else if (type == 'friend_rejected' || type == 'friend_removed') {
        ref.read(friendsProvider.notifier).removeFriend(fromHex);
      } else if (type == 'nick_changed') {
        final newName = parts.sublist(2).join(':');
        ref.read(friendsProvider.notifier).updateFriendName(fromHex, newName);
      }
    }));

    _syncSubscriptions.add(iroh.messageStream.listen(_handleIncomingMessage));

    _syncSubscriptions.add(iroh.fileTransferStream.listen((progress) {
      ref.read(fileTransfersProvider.notifier).update((m) {
        return {...m, progress.transferId: progress};
      });
    }));

    _syncSubscriptions.add(iroh.fileDownloadStream.listen(_handleFileDownloaded));

    _syncSubscriptions.add(iroh.incomingFileStream.listen(_showIncomingFileOffer));

    _syncSubscriptions.add(iroh.callEventStream.listen(_handleCallEvent));
  }

  /// Non-intrusive toast after a friend request is accepted, with a shortcut
  /// into the chat. Callee may be on any screen, so we navigate on the root
  /// navigator instead of any screen context.
  void _offerChatAfterAccept(Friend friend) {
    final nav = _navKey.currentState;
    if (nav == null) return;
    ScaffoldMessenger.of(nav.context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
        content: Text('${friend.displayName} accepted your friend request'),
        action: SnackBarAction(
          label: 'Chat',
          onPressed: () {
            nav.push(
              MaterialPageRoute(
                builder: (_) => ChatScreen(friend: friend),
              ),
            );
          },
        ),
      ),
    );
  }

  void _handleCallEvent(CallEvent e) {
    if (e.phase == CallPhase.idle) {
      _callScreenOpen = false;
      return;
    }
    if (_callScreenOpen) return;
    final nav = _navKey.currentState;
    if (nav == null) return;
    _callScreenOpen = true;
    showDialog<void>(
      context: nav.context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: CallScreen(initialEvent: e),
      ),
    ).then((_) {
      if (mounted) _callScreenOpen = false;
    });
  }

  /// Prompts the user to accept an inbound file offer and pick a save
  /// location. Only after "Accept" does the sender start streaming the bytes.
  Future<void> _showIncomingFileOffer(IncomingFileOffer offer) async {
    final iroh = IrohService();
    final nav = _navKey.currentState;
    if (nav == null) {
      iroh.respondIncomingFile(offer.fileId, false);
      return;
    }

    // Update packages we explicitly requested from a friend (no auto-push of
    // strangers, and only the exact package name the friend's reply promised):
    // accept straight into the updates/ dir, skip the dialog.
    if (iroh.isAwaitingUpdateFrom(offer.fromHex, fileName: offer.name) &&
        UpdateService.isUpdatePackageName(offer.name)) {
      try {
        final support = await getApplicationSupportDirectory();
        final updatesDir = '${support.path}${Platform.pathSeparator}updates';
        iroh.respondIncomingFile(offer.fileId, true, savePath: updatesDir);
        final ver = UpdateService.updateVersionFromName(offer.name);
        _showOnNav(nav,
            ver == null ? '正在接收好友更新...' : '正在接收好友更新 v$ver ...');
      } catch (e) {
        iroh.respondIncomingFile(offer.fileId, true); // default save folder
      }
      return;
    }

    String? target;
    // Replace any still-open previous offer dialog before showing a new one so
    // unanswered retries don't stack dialogs on top of each other.
    _fileOfferDialogNav?.pop();
    _fileOfferDialogNav = nav;
    final accepted = await showDialog<bool>(
      context: nav.context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setState) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.download, color: AppTheme.primaryColor),
                SizedBox(width: 8),
                Expanded(
                  child: Text('Incoming file', style: TextStyle(fontSize: 18)),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${offer.fromName} wants to send you a file:'),
                const SizedBox(height: 8),
                Text(
                  offer.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(_formatFileSize(offer.size)),
                if (offer.compressed)
                  const Text('(compressed)',
                      style: TextStyle(color: AppTheme.textSecondary)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.folder_outlined, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Save to: ${target ?? "App download folder"}',
                        style: const TextStyle(color: AppTheme.textSecondary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Save file to');
                        if (dir != null) setState(() => target = dir);
                      },
                      child: const Text('Choose location'),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Decline'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Accept & receive'),
              ),
            ],
          ),
        );
      },
    );

    iroh.respondIncomingFile(
      offer.fileId,
      accepted ?? false,
      savePath: target,
    );
    _fileOfferDialogNav = null;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  void _handleFileDownloaded(FileDownloaded downloaded) {
    final friendId = downloaded.fromHex;
    // A completed transfer proves the peer's connection is live, so it must
    // count as online even if the periodic probe has not replied yet.
    ref.read(friendsProvider.notifier).setFriendOnline(friendId, true);
    unawaited(IrohService().notifyFriendOnline(friendId));
    final friends = ref.read(friendsProvider);
    final existing = friends.any((f) => f.id == friendId);
    final now = DateTime.now();
    if (!existing) {
      ref.read(friendsProvider.notifier).addFriend(Friend(
        id: friendId,
        name: downloaded.fromHex.substring(0, 12),
        shortId: '',
        status: FriendStatus.accepted,
        createdAt: now,
      ));
    }

    final msg = Message(
      id: 'file_${downloaded.transferId}',
      senderId: friendId,
      receiverId: ref.read(appStateProvider).userId ?? '',
      content: '[File] ${downloaded.fileName}',
      timestamp: now,
      type: MessageType.file,
      isMe: false,
      status: MessageStatus.delivered,
      fileName: downloaded.fileName,
      filePath: downloaded.filePath,
      fileSize: downloaded.fileSize,
      transferId: downloaded.transferId,
    );
    ref.read(messagesProvider(friendId).notifier).addMessage(msg);
    ref.read(friendsProvider.notifier).updateLastMessage(
      friendId,
      '[File] ${downloaded.fileName}',
      now,
    );
    final activeChat = ref.read(activeChatIdProvider);
    if (activeChat != friendId) {
      ref.read(friendsProvider.notifier).incrementUnread(friendId);
    }

    IrohService().clearAwaitingUpdate(friendId);
    if (UpdateService.isUpdatePackageName(downloaded.fileName)) {
      _handleUpdatePackageReceived(downloaded);
    }
  }

  /// Surfaces a P2P-received update bundle and applies it with per-file progress.
  /// Supports .zip (differential update with manifest) and .exe (full installer).
  void _handleUpdatePackageReceived(FileDownloaded downloaded) {
    if (!mounted) return;
    final nav = _navKey.currentState;
    if (nav == null) return;
    final name = downloaded.fileName.toLowerCase();
    final ver = UpdateService.updateVersionFromName(downloaded.fileName);
    final label = ver == null ? downloaded.fileName : 'v$ver';
    final isExe = name.endsWith('.exe');
    final isZip = name.endsWith('.zip');

    if (isZip) {
      _showZipUpdateDialog(nav, downloaded, label);
    } else if (isExe) {
      _showExeInstallDialog(nav, downloaded, label);
    } else {
      _showGenericFileDialog(nav, downloaded, label);
    }
  }

  void _showZipUpdateDialog(NavigatorState nav, FileDownloaded downloaded, String label) {
    showDialog<void>(
      context: nav.context,
      barrierDismissible: false,
      builder: (dialogContext) {
        String status = '准备应用更新...';
        double progress = 0.0;
        String currentFile = '';
        int curDone = 0;
        int fileTotal = 0;
        bool startScheduled = false;

        return StatefulBuilder(
          builder: (dialogContext, setState) {
            // Start extraction exactly once: StatefulBuilder re-runs this
            // callback on every setState, and re-scheduling would launch
            // concurrent applies of the same archive.
            if (!startScheduled) {
              startScheduled = true;
              Future.microtask(() async {
                final result = await UpdateService.applyUpdateFromZip(
                  downloaded.filePath,
                  onProgress: (cur, tot, fileName) {
                    if (mounted) {
                      setState(() {
                        curDone = cur;
                        fileTotal = tot;
                        currentFile = fileName;
                        progress = tot > 0 ? cur / tot : 0.0;
                        status = '正在更新: $currentFile ($curDone/$fileTotal)';
                      });
                    }
                  },
                );
                if (!mounted) return;
                Navigator.of(dialogContext).pop();
                if (result.ok) {
                  _showOnNav(nav, '更新完成: ${result.message}。重启应用以生效。');
                  // Auto-restart after a short delay
                  Future.delayed(const Duration(seconds: 3), () {
                    if (Platform.isWindows) {
                      Process.start(Platform.resolvedExecutable, [],
                          mode: ProcessStartMode.detached);
                      exit(0);
                    }
                  });
                } else {
                  _showOnNav(nav, '更新失败: ${result.message}');
                }
              });
            }

            return AlertDialog(
              title: Text('正在应用更新 $label'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('文件来源：${downloaded.fromHex.substring(0, 12)}...'),
                  const SizedBox(height: 16),
                  Text(status),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: progress > 0 ? progress : null),
                  if (curDone > 0 && fileTotal > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('$curDone / $fileTotal 文件',
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textSecondary)),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showExeInstallDialog(NavigatorState nav, FileDownloaded downloaded, String label) {
    showDialog<void>(
      context: nav.context,
      builder: (dialogContext) => AlertDialog(
        title: Text('收到好友更新 $label'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('文件来源：${downloaded.fromHex.substring(0, 12)}...'),
            const SizedBox(height: 8),
            Text(downloaded.filePath,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary, overflow: TextOverflow.ellipsis)),
            const SizedBox(height: 8),
            const Text('安装程序已就绪，点击安装后将重启应用。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('以后再说'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              try {
                await Process.start(downloaded.filePath, [], mode: ProcessStartMode.normal);
                exit(0);
              } catch (e) {
                _showOnNav(nav, '启动安装程序失败：$e');
              }
            },
            child: const Text('立即安装'),
          ),
        ],
      ),
    );
  }

  void _showGenericFileDialog(NavigatorState nav, FileDownloaded downloaded, String label) {
    showDialog<void>(
      context: nav.context,
      builder: (dialogContext) => AlertDialog(
        title: Text('收到好友文件 $label'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('文件来源：${downloaded.fromHex.substring(0, 12)}...'),
            const SizedBox(height: 8),
            Text(downloaded.filePath,
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, overflow: TextOverflow.ellipsis)),
            const SizedBox(height: 8),
            const Text('请手动处理此文件。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showOnNav(NavigatorState nav, String text) {
    ScaffoldMessenger.of(nav.context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  void _handleIncomingMessage(Message msg) {
    if (msg.isMe) return;
    final friendId = msg.senderId;
    // Receiving a message proves the sender's connection is live, so surface
    // them as online immediately instead of waiting for the next probe round.
    ref.read(friendsProvider.notifier).setFriendOnline(friendId, true);
    unawaited(IrohService().notifyFriendOnline(friendId));
    if (msg.senderName != null && msg.senderName!.trim().isNotEmpty) {
      final friend = ref
          .read(friendsProvider)
          .where((f) => f.id == friendId)
          .firstOrNull;
      if (friend != null && friend.name.trim().isEmpty) {
        ref
            .read(friendsProvider.notifier)
            .updateFriendName(friendId, msg.senderName!);
      }
    }
    ref.read(messagesProvider(friendId).notifier).addMessage(msg);
    ref
        .read(friendsProvider.notifier)
        .updateLastMessage(friendId, msg.content, msg.timestamp);
    final activeChat = ref.read(activeChatIdProvider);
    if (activeChat != friendId) {
      ref.read(friendsProvider.notifier).incrementUnread(friendId);
    }
    if (NotificationService.instance.appInBackground) {
      final name = (msg.senderName?.trim().isNotEmpty ?? false)
          ? msg.senderName!
          : friendId.substring(0, 8);
      NotificationService.instance.showIncomingMessage(
        title: name,
        body: msg.content,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);

    return MaterialApp(
      title: 'Wave',
      navigatorKey: _navKey,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: appState.themeMode,
      home: SplashScreen(irohReady: widget.irohReady),
    );
  }
}
