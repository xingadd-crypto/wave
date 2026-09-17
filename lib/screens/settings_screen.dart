import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_wave/theme/app_theme.dart';
import 'package:flutter_wave/models/app_state.dart';
import 'package:flutter_wave/models/friend.dart';
import 'package:flutter_wave/providers/app_provider.dart';
import 'package:flutter_wave/services/app_version.dart';
import 'package:flutter_wave/services/update_service.dart';
import 'package:flutter_wave/services/iroh_service.dart';
import 'package:flutter_wave/services/qr_payload.dart';
import 'package:flutter_wave/services/ultrasonic.dart';
import 'package:flutter_wave/services/persistence_service.dart';
import 'package:flutter_wave/services/background_service.dart';
import 'package:flutter_wave/services/notification_service.dart';
import 'package:flutter_wave/screens/email_sync_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _ultrasonic = Ultrasonic();
  bool _backgroundEnabled = false;
  bool _backgroundBusy = false;
  bool _updateBusy = false;
  String _updateUrl = '';

  @override
  void initState() {
    super.initState();
    _loadBackgroundMode();
    _loadUpdateUrl();
  }

  Future<void> _loadUpdateUrl() async {
    final url = await PersistenceService.loadUpdateUrl();
    if (mounted) setState(() => _updateUrl = url);
  }

  @override
  void dispose() {
    _ultrasonic.dispose();
    super.dispose();
  }

  Future<void> _loadBackgroundMode() async {
    final enabled = await BackgroundService.loadEnabled();
    if (mounted) setState(() => _backgroundEnabled = enabled);
  }

  Future<void> _toggleBackground(bool value) async {
    if (_backgroundBusy) return;
    setState(() => _backgroundBusy = true);
    if (value) {
      await NotificationService.instance.requestPermission();
      final result = await BackgroundService.start();
      if (result is ServiceRequestSuccess) {
        await BackgroundService.setEnabled(true);
        if (mounted) setState(() => _backgroundEnabled = true);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start background mode')),
        );
      }
    } else {
      await BackgroundService.stop();
      await BackgroundService.setEnabled(false);
      if (mounted) setState(() => _backgroundEnabled = false);
    }
    if (mounted) setState(() => _backgroundBusy = false);
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 24,
          ),
        ),
      ),
      body: ListView(
        children: [
          _buildProfileSection(appState),
          const Divider(),
          _buildNetworkSection(),
          const Divider(),
          _buildBackgroundSection(),
          const Divider(),
          _buildAppearanceSection(appState),
          const Divider(),
          _buildUpdateSection(),
          const Divider(),
          _buildFriendVersionsSection(),
          const Divider(),
          _buildAboutSection(),
        ],
      ),
    );
  }

  Widget _buildProfileSection(AppState appState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                child: Text(
                  (appState.nickname == null || appState.nickname!.isEmpty)
                      ? '?'
                      : appState.nickname![0].toUpperCase(),
                  style: const TextStyle(
                    fontSize: 32,
                    color: AppTheme.primaryColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appState.nickname ?? 'Unknown',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      appState.shortId != null
                          ? '#${appState.shortId}'
                          : 'Not registered',
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () {
                  _showEditNicknameDialog();
                },
              ),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.copy),
          title: const Text('Copy Short ID'),
          subtitle: Text(
            appState.shortId != null ? '#${appState.shortId}' : 'Not registered',
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textHint,
            ),
          ),
          onTap: () {
            if (appState.shortId != null) {
              Clipboard.setData(ClipboardData(text: appState.shortId!));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Short ID copied!'),
                ),
              );
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.vpn_key),
          title: const Text('My Public Key'),
          subtitle: Text(
            appState.userId?.substring(0, 20) ?? 'Unknown',
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textHint,
            ),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.qr_code_2),
            tooltip: 'Show QR code',
            onPressed: _showQrDialog,
          ),
          onTap: () {
            if (appState.userId != null) {
              Clipboard.setData(ClipboardData(text: appState.userId!));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Public key copied!'),
                ),
              );
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.qr_code),
          title: const Text('My QR Code'),
          subtitle: Text(
            appState.shortId != null ? 'Scan to add me offline' : 'Not registered',
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textHint,
            ),
          ),
          onTap: _showQrDialog,
        ),
        ListTile(
          leading: const Icon(Icons.speaker),
          title: const Text('My Sound Code'),
          subtitle: const Text(
            'Play a sound so other devices can listen & add me offline',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textHint,
            ),
          ),
          onTap: _showSoundCodeDialog,
        ),
        ListTile(
          leading: Icon(
            appState.isConnected ? Icons.cloud_done : Icons.cloud_off,
            color: appState.isConnected ? AppTheme.successColor : AppTheme.errorColor,
          ),
          title: const Text('Connection Status'),
          subtitle: Text(
            appState.isConnected ? 'Connected' : 'Disconnected',
            style: TextStyle(
              color: appState.isConnected ? AppTheme.successColor : AppTheme.errorColor,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNetworkSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Network',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: AppTheme.primaryColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.sync),
          title: const Text('Reconnect'),
          onTap: () async {
            final appStateNotifier = ref.read(appStateProvider.notifier);
            await appStateNotifier.connectToServer();
          },
        ),
        ListTile(
          leading: const Icon(Icons.mark_email_read_outlined),
          title: const Text('Email Sync'),
          subtitle: const Text(
            'Back up identity & friends to your own mailbox (encrypted)',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textHint,
            ),
          ),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EmailSyncScreen()),
            );
          },
        ),
      ],
    );
  }

  Widget _buildBackgroundSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Background',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: AppTheme.primaryColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.notifications_active_outlined),
          title: const Text('Background messages'),
          subtitle: const Text(
            'Keeps Wave running in the background and notifies you of new messages',
          ),
          value: _backgroundEnabled,
          onChanged: _backgroundBusy ? null : _toggleBackground,
        ),
      ],
    );
  }

  Widget _buildAppearanceSection(AppState appState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Appearance',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: AppTheme.primaryColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.dark_mode),
          title: const Text('Dark Mode'),
          value: appState.themeMode == ThemeMode.dark,
          onChanged: (value) {
            ref.read(appStateProvider.notifier).toggleTheme();
          },
        ),
      ],
    );
  }

  Widget _buildAboutSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'About',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: AppTheme.primaryColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Version'),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            'v$appVersion',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Center(
          child: Text(
            'Wave - P2P Instant Messenger',
            style: TextStyle(
              color: AppTheme.textHint,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildUpdateSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Update',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: AppTheme.primaryColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.system_update_alt),
          title: const Text('Check for updates'),
          subtitle: Text(
            _updateUrl.trim().isEmpty ? 'OTA source not configured' : 'v$appVersion',
          ),
          trailing: _updateBusy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: _updateBusy ? null : _checkForUpdate,
        ),
        ListTile(
          leading: const Icon(Icons.link),
          title: const Text('Update source (latest.json)'),
          subtitle: Text(
            _updateUrl.trim().isEmpty ? 'Not configured' : _updateUrl,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: _configureUpdateUrl,
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  /// P2P version exchange: friends running 1.0.27+ announce their version in
  /// the presence handshake. When an online friend reports a newer version,
  /// the user can manually fetch its platform-matching package (各平台对应各平台
  /// 版本) — no auto-push from the friend side.
  Widget _buildFriendVersionsSection() {
    final friends = ref
        .watch(friendsProvider)
        .where((f) => f.status == FriendStatus.accepted)
        .toList();
    final withVersion = friends
        .where((f) => f.version != null && f.version!.trim().isNotEmpty)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            '好友版本',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: AppTheme.textSecondary,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '在线好友运行更高版本时，可手动获取更新包。各版本只负责本版平台更新（Android 版发 APK、Windows 版发 EXE/ZIP），跨平台不可获取。',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
        ),
        const SizedBox(height: 4),
        if (withVersion.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '暂无好友版本信息（需对方使用 1.0.27+ 并在在线探测后刷新）',
              style: TextStyle(color: AppTheme.textHint),
            ),
          )
        else
          for (final f in withVersion) _friendVersionTile(f),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: _prepareUpdateForFriends,
            icon: const Icon(Icons.share, size: 18),
            label: const Text('准备当前版本供好友更新'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.primaryColor,
              side: BorderSide(color: AppTheme.primaryColor),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Future<void> _prepareUpdateForFriends() async {
    final result = await UpdateService.prepareUpdateForFriends();
    if (!mounted) return;
    if (result.ok) {
      await _showMessage('准备完成', result.message);
    } else {
      await _showMessage('准备失败', result.message);
    }
  }

  Widget _friendVersionTile(Friend f) {
    final newer = UpdateService.isNewerThan(appVersion, f.version!);
    final myPlat = Platform.isAndroid ? 'android' : 'windows';
    final samePlatform = f.platform == null || f.platform == myPlat;
    final canFetch = newer && f.isOnline && samePlatform;
    final tag = switch (f.platform) {
      'android' => 'Android',
      'windows' => 'Windows',
      _ => '',
    };
    return ListTile(
      dense: true,
      leading: const Icon(Icons.person_outline),
      title: Text(f.displayName),
      subtitle: Text(
        'v${f.version}${tag.isEmpty ? '' : ' ($tag)'}'
        '${newer ? '  （有更新）' : ''}',
        style: TextStyle(
          color: newer ? AppTheme.successColor : AppTheme.textHint,
          fontWeight: newer ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.download),
        tooltip: !samePlatform
            ? '对方为 $tag 版，不提供 $myPlat 平台更新包'
            : (canFetch
                ? '从该好友获取更新'
                : (newer ? '好友不在线' : '对方版本不高于当前')),
        onPressed: canFetch ? () => _fetchFromFriend(f) : null,
      ),
    );
  }

  Future<void> _fetchFromFriend(Friend friend) async {
    // Track whether the progress dialog is still up: if the user taps 取消 the
    // request keeps running in the background, and we must NOT pop the root
    // navigator again (that would dismiss the Settings screen itself).
    var dialogOpen = false;
    if (mounted) {
      dialogOpen = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Text('正在请求 ${friend.displayName} 的更新包...'),
            actions: [
              TextButton(
                onPressed: () {
                  dialogOpen = false;
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      );
    }
    final result = await IrohService().requestFriendUpdate(friend);
    if (dialogOpen && mounted) {
      dialogOpen = false;
      Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return;
    if (result.ok) {
      await _showMessage(
        '已获取更新',
        result.fileName == null
            ? '好友正在发送更新，接收完成后会弹出安装提示。'
            : '好友将发送 ${result.fileName}。接收完成后会弹出安装提示。',
      );
    } else {
      await _showMessage('获取失败', result.reason ?? '好友未响应');
    }
  }

  Future<void> _checkForUpdate() async {
    setState(() => _updateBusy = true);
    UpdateCheckResult result;
    try {
      result = await UpdateService.checkForUpdate(manifestUrl: _updateUrl);
    } finally {
      if (mounted) setState(() => _updateBusy = false);
    }
    if (!mounted) return;
    if (result.skipped) {
      await _showMessage('未配置更新源', '请先在「Update source」中填写 latest.json 的地址。');
    } else if (result.error != null) {
      await _showMessage('检查更新失败', '${result.error}');
    } else if (!result.available) {
      final info = result.info;
      await _showMessage(
        '已是最新版本',
        '当前版本 v$appVersion。${info == null ? '' : '清单版本 v${info.version} 相同或更低。'}',
      );
    } else {
      await _showUpdateAvailable(result.info!);
    }
  }

  Future<void> _showUpdateAvailable(UpdateInfo info) async {
    final url = Platform.isWindows
        ? (info.windowsUrl ?? info.androidUrl)
        : (info.androidUrl ?? info.windowsUrl);
    final sha = Platform.isWindows
        ? (info.windowsSha256 ?? info.androidSha256)
        : (info.androidSha256 ?? info.windowsSha256);
    final shouldDownload = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('发现新版本 v${info.version}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '当前 v$appVersion',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            if (info.notes != null && info.notes!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(info.notes!),
              ),
            const SizedBox(height: 8),
            if (url == null || url.isEmpty)
              const Text(
                '清单未包含当前平台的下载地址。',
                style: TextStyle(color: Colors.orange),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          if (url != null && url.isNotEmpty)
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('下载更新'),
            ),
        ],
      ),
    );
    if (shouldDownload != true || url == null || url.isEmpty) return;

    await _downloadAndInstall(info: info, url: url, sha256: sha);
  }

  Future<void> _downloadAndInstall({
    required UpdateInfo info,
    required String url,
    String? sha256,
  }) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('正在下载 v${info.version} ...'),
            ],
          ),
        ),
      ),
    );

    try {
      final support = await getApplicationSupportDirectory();
      final dest =
          '${support.path}${Platform.pathSeparator}updates${Platform.pathSeparator}'
          '${UpdateService.packageFileName(info.version)}';
      await UpdateService.downloadFile(
        url: url,
        destPath: dest,
        sha256: sha256,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      if (Platform.isWindows) {
        await Process.start(dest, [], mode: ProcessStartMode.normal);
        await _showMessage('下载完成', '安装程序已启动：\n$dest');
      } else {
        await _showMessage(
          '下载完成',
          'APK 已保存到：\n$dest\n\n请通过文件管理器打开并安装（需允许安装未知来源应用）。',
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        await _showMessage('更新失败', '$e');
      }
    }
  }

  Future<void> _configureUpdateUrl() async {
    final controller = TextEditingController(text: _updateUrl);
    final saved = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('更新源 (latest.json)'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            hintText: 'https://example.com/wave/latest.json',
            helperText: '留空并保存可关闭自动检查',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(''),
            child: const Text('清空'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(null),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == null) return;
    final url = saved.trim();
    await PersistenceService.saveUpdateSettings(url: url);
    if (mounted) setState(() => _updateUrl = url);
    if (url.isEmpty) {
      await _showMessage('已关闭', 'OTA 自动检查已禁用。');
    } else {
      await _checkForUpdate();
    }
  }

  Future<void> _showMessage(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showQrDialog() {
    final appState = ref.read(appStateProvider);
    final userId = appState.userId;
    if (userId == null) return;

    final payload = QrPayload.build(
      publicKeyHex: userId,
      shortId: appState.shortId,
      name: appState.nickname,
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(24, 20, 8, 0),
        title: Row(
          children: [
            Expanded(
              child: Text(
                appState.nickname ?? 'Unknown',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: payload,
                version: QrVersions.auto,
                size: 220,
                gapless: true,
              ),
            ),
            const SizedBox(height: 16),
            if (appState.shortId != null && appState.shortId!.isNotEmpty)
              Text(
                '#${appState.shortId}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            const SizedBox(height: 6),
            Text(
              userId,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Scan this QR with the Wave app on another device '
              'to add me as a friend offline.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.textHint,
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: payload));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('QR payload copied!')),
              );
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy QR data'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showSoundCodeDialog() {
    final appState = ref.read(appStateProvider);
    final userId = appState.userId;
    if (userId == null) return;

    final payload = QrPayload.build(
      publicKeyHex: userId,
      shortId: appState.shortId,
      name: appState.nickname,
    );

    showDialog(
      context: context,
      builder: (_) =>
          _SoundCodeDialog(ultrasonic: _ultrasonic, payload: payload),
    );
  }

  void _showEditNicknameDialog() {
    final controller = TextEditingController(
      text: ref.read(appStateProvider).nickname,
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Nickname'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Nickname',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final newNickname = controller.text.trim();
              if (newNickname.isNotEmpty) {
                ref.read(appStateProvider.notifier).updateNickname(
                  newNickname,
                  friends: ref.read(friendsProvider),
                );
                Navigator.pop(context);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/// Plays this device's sound code so a nearby Wave device can listen and add
/// this user offline.
class _SoundCodeDialog extends StatefulWidget {
  const _SoundCodeDialog({required this.ultrasonic, required this.payload});

  final Ultrasonic ultrasonic;
  final String payload;

  @override
  State<_SoundCodeDialog> createState() => _SoundCodeDialogState();
}

class _SoundCodeDialogState extends State<_SoundCodeDialog> {
  bool _audible = true;
  bool _playing = false;

  Future<void> _play() async {
    if (_playing) return;
    setState(() => _playing = true);
    final ms = await widget.ultrasonic.playPayload(
      widget.payload,
      audible: _audible,
    );
    if (!mounted) return;
    setState(() => _playing = false);
    if (ms == 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not play the sound code')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('My Sound Code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Keep the two devices close (speaker toward microphone). Tap '
            'Play here — the code plays twice — while the other device is '
            'already listening from Contacts > "add Friend" > "Listen for '
            'Sound Code". It decodes even from a voice-chat echo.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 18),
          _playing
              ? const SizedBox.square(
                  dimension: 56,
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                )
              : Icon(
                  Icons.waves,
                  size: 56,
                  color: AppTheme.primaryColor.withValues(alpha: 0.7),
                ),
          const SizedBox(height: 12),
          Text(
            _playing
                ? 'Playing…'
                : (_audible
                    ? 'Ready (audible tones ~2–9 kHz)'
                    : 'Ready (ultrasound ~15–22 kHz)'),
            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Ultrasound'),
                selected: !_audible,
                onSelected: _playing
                    ? null
                    : (_) => setState(() => _audible = false),
              ),
              ChoiceChip(
                label: const Text('Audible'),
                selected: _audible,
                onSelected: _playing
                    ? null
                    : (_) => setState(() => _audible = true),
              ),
            ],
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _playing ? null : _play,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Play'),
        ),
      ],
    );
  }
}
