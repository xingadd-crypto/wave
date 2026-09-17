import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_wave/theme/app_theme.dart';
import 'package:flutter_wave/models/friend.dart';
import 'package:flutter_wave/providers/app_provider.dart';
import 'package:flutter_wave/services/qr_payload.dart';
import 'package:flutter_wave/services/ultrasonic.dart';
import 'package:flutter_wave/widgets/friend_list_item.dart';
import 'package:flutter_wave/screens/chat_screen.dart';
import 'package:flutter_wave/screens/qr_scan_screen.dart';

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _ultrasonic = Ultrasonic();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _ultrasonic.dispose();
    super.dispose();
  }

  void _openChat(Friend friend) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatScreen(friend: friend)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final friends = ref.watch(friendsProvider);

    final acceptedFriends = friends.where((f) => f.status == FriendStatus.accepted).toList();
    final pendingInFriends = friends.where((f) => f.status == FriendStatus.pendingIn).toList();
    final pendingOutFriends = friends.where((f) => f.status == FriendStatus.pendingOut).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Contacts',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Scan QR code',
            onPressed: _scanQr,
          ),
          IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: 'Add Friend',
            onPressed: _showAddFriendSheet,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: 'Friends (${acceptedFriends.length})'),
            Tab(text: 'Requests (${pendingInFriends.length})'),
            Tab(text: 'Pending (${pendingOutFriends.length})'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildFriendsList(acceptedFriends),
          _buildRequestsList(pendingInFriends),
          _buildPendingList(pendingOutFriends),
        ],
      ),
    );
  }

  Widget _buildFriendsList(List<Friend> friends) {
    if (friends.isEmpty) {
      return _buildEmptyState(
        'No friends yet',
        'Scan a QR code or press @ to add friends',
      );
    }

    return ListView.builder(
      itemCount: friends.length,
      itemBuilder: (context, index) {
        final friend = friends[index];
        return FriendListItem(
          friend: friend,
          onTap: () => _openChat(friend),
          onLongPress: () => _showFriendOptions(friend),
        );
      },
    );
  }

  Widget _buildRequestsList(List<Friend> requests) {
    if (requests.isEmpty) {
      return _buildEmptyState('No pending requests', 'Friend requests will appear here');
    }

    return ListView.builder(
      itemCount: requests.length,
      itemBuilder: (context, index) {
        final request = requests[index];
        return FriendListItem(
          friend: request,
          showActions: true,
          onAccept: () async {
            await ref.read(irohServiceProvider).acceptFriendRequest(request.id);
            ref.read(friendsProvider.notifier).updateFriend(
              request.copyWith(status: FriendStatus.accepted),
            );
          },
          onReject: () async {
            await ref.read(irohServiceProvider).rejectFriendRequest(request.id);
            ref.read(friendsProvider.notifier).removeFriend(request.id);
          },
        );
      },
    );
  }

  Widget _buildPendingList(List<Friend> pending) {
    if (pending.isEmpty) {
      return _buildEmptyState('No pending requests', 'Outgoing friend requests will appear here');
    }

    return ListView.builder(
      itemCount: pending.length,
      itemBuilder: (context, index) {
        final friend = pending[index];
        return FriendListItem(
          friend: friend,
          onTap: () => _openChat(friend),
          onLongPress: () => _showFriendOptions(friend),
          showCancelButton: true,
          onCancel: () {
            ref.read(friendsProvider.notifier).removeFriend(friend.id);
          },
        );
      },
    );
  }

  Widget _buildEmptyState(String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_outline, size: 80, color: AppTheme.textHint.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          Text(subtitle,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppTheme.textHint)),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () {
              _showAddFriendSheet();
            },
            icon: const Icon(Icons.person_add),
            label: const Text('Add Friend'),
          ),
        ],
      ),
    );
  }

  // --- Add-friend entry points (moved from Discover) ----------------------

  void _showAddFriendSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.person_add_alt, color: AppTheme.primaryColor),
              title: Text('Add Friend', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('Scan QR Code'),
              subtitle: const Text('Point your camera at another device\u2019s "My QR Code"'),
              onTap: () {
                Navigator.pop(context);
                _scanQr();
              },
            ),
            ListTile(
              leading: const Icon(Icons.explore_outlined),
              title: const Text('Browse Online Users'),
              subtitle: const Text('Look up registered users on the shared network'),
              onTap: () {
                Navigator.pop(context);
                _showOnlineUsersDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.graphic_eq),
              title: const Text('Listen for Sound Code'),
              subtitle: const Text('Hear a nearby "My Sound Code" and add its sender offline'),
              onTap: () {
                Navigator.pop(context);
                _listenAndAdd();
              },
            ),
            ListTile(
              leading: const Icon(Icons.key),
              title: const Text('Paste Public Key'),
              subtitle: const Text('Paste a wave:pk:… payload or a 64-char public key'),
              onTap: () {
                Navigator.pop(context);
                _showAddByKeyDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.tag),
              title: const Text('Add by Short ID / EID'),
              subtitle: const Text('Look up a registered short ID or connect directly by eid'),
              onTap: () {
                Navigator.pop(context);
                _showShortIdDialog();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanQr() async {
    final payload = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (payload == null || !mounted) return;
    await _addByPublicKey(payload);
  }

  Future<void> _listenAndAdd() async {
    if (!mounted) return;
    final payload = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SoundListenDialog(ultrasonic: _ultrasonic),
    );
    if (payload == null || !mounted) return;
    await _addByPublicKey(payload);
  }

  Future<void> _addByPublicKey(String payload) async {
    final parsed = QrPayload.parse(payload);
    if (parsed == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Not a valid Wave public key or QR payload'),
            backgroundColor: AppTheme.warningColor,
          ),
        );
      }
      return;
    }

    final hex = parsed['p']!;

    final friends = ref.read(friendsProvider);
    final existing = friends.where((f) => f.id.toLowerCase() == hex).toList();
    if (existing.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${existing.first.displayName} is already on '
                'your friend list'),
            backgroundColor: AppTheme.successColor,
          ),
        );
      }
      return;
    }

    final ok = await ref
        .read(irohServiceProvider)
        .sendFriendRequestById(hex);

    if (!mounted) return;
    if (ok) {
      _addPendingOutFriend(
        id: hex,
        name: parsed['n'],
        shortId: parsed['s'],
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Friend request sent!'),
          backgroundColor: AppTheme.successColor,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to send friend request'),
          backgroundColor: AppTheme.warningColor,
        ),
      );
    }
  }

  /// Mirrors the CLI's `/f add`: the requester also stores the target locally
  /// as a pending-out friend, so an upcoming `friend_accepted` event can flip
  /// it to accepted (and presence probing covers it too).
  void _addPendingOutFriend({
    required String id,
    String? name,
    String? shortId,
  }) {
    if (id.isEmpty) return;
    final friends = ref.read(friendsProvider);
    if (friends.any((f) => f.id == id)) return;
    final cleanName =
        (name != null && name.trim().isNotEmpty) ? name.trim() : _nameFromHex(id);
    ref.read(friendsProvider.notifier).addFriend(Friend(
          id: id,
          name: cleanName,
          shortId: shortId?.trim() ?? '',
          status: FriendStatus.pendingOut,
          createdAt: DateTime.now(),
        ));
  }

  String _nameFromHex(String hex) {
    if (hex.length >= 8) return 'Friend ${hex.substring(0, 8)}';
    if (hex.isNotEmpty) return 'Friend $hex';
    return 'Friend';
  }

  void _showAddByKeyDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add by Public Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste a public key, or a wave:pk:… payload copied from '
              'another device\u2019s "My QR Code". Works even when the '
              'device is offline (via shared relay).',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 3,
              autofocus: true,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
              ),
              decoration: InputDecoration(
                hintText: 'wave:pk:… or 64-char hex',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onSubmitted: (_) {
                final payload = controller.text.trim();
                if (payload.isEmpty) return;
                Navigator.pop(context);
                _addByPublicKey(payload);
              },
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () async {
                final text = await Clipboard.getData(Clipboard.kTextPlain);
                if (text?.text != null && text!.text!.isNotEmpty) {
                  controller.text = text.text!;
                }
              },
              icon: const Icon(Icons.content_paste, size: 18),
              label: const Text('Paste from clipboard'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final payload = controller.text.trim();
              if (payload.isEmpty) return;
              Navigator.pop(context);
              _addByPublicKey(payload);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }

  void _showShortIdDialog() {
    final shortIdController = TextEditingController();
    final eidController = TextEditingController();
    bool useEid = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Add Friend'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Short ID')),
                  ButtonSegment(value: true, label: Text('EID')),
                ],
                selected: {useEid},
                onSelectionChanged: (s) => setState(() => useEid = s.first),
              ),
              const SizedBox(height: 12),
              if (useEid)
                TextField(
                  controller: eidController,
                  decoration: const InputDecoration(
                    labelText: 'Endpoint ID (eid)',
                    hintText: '64-char public key hex, e.g. cb5a...',
                    prefixIcon: Icon(Icons.key),
                    helperText: 'Connect directly by eid, no Moon server needed',
                  ),
                  maxLines: 2,
                )
              else
                TextField(
                  controller: shortIdController,
                  decoration: const InputDecoration(
                    labelText: 'Short ID',
                    hintText: "Enter friend's short ID",
                    prefixIcon: Icon(Icons.tag),
                  ),
                  keyboardType: TextInputType.number,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final iroh = ref.read(irohServiceProvider);
                // The dialog's own context + root messenger are captured before
                // any await so a screen unmount mid-flight can never make us
                // touch a stale BuildContext.
                final dialogNavigator = Navigator.of(context);
                final messenger = ScaffoldMessenger.of(context);
                Friend? newFriend;
                bool sent = false;

                if (useEid) {
                  final eid = eidController.text.trim();
                  if (eid.isEmpty) return;
                  sent = await iroh.sendFriendRequestById(eid);
                  if (sent) {
                    final peerHex = eid.toLowerCase();
                    newFriend = Friend(
                      id: peerHex,
                      name: '',
                      shortId: '',
                      status: FriendStatus.pendingOut,
                      createdAt: DateTime.now(),
                    );
                    ref.read(friendsProvider.notifier).addFriend(newFriend);
                  }
                } else {
                  final shortId = shortIdController.text.trim();
                  if (shortId.isEmpty) return;
                  final entry = await iroh.lookupUser(shortId);
                  if (entry != null) {
                    final peerHex = entry.id.fold('', (h, b) => '$h${b.toRadixString(16).padLeft(2, '0')}');
                    newFriend = Friend(
                      id: peerHex,
                      name: entry.name,
                      shortId: entry.shortId,
                      status: FriendStatus.pendingOut,
                      createdAt: DateTime.now(),
                    );
                    ref.read(friendsProvider.notifier).addFriend(newFriend);
                    await iroh.sendFriendRequest(shortId);
                    sent = true;
                  }
                }

                dialogNavigator.pop();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      sent
                          ? 'Friend request sent!'
                          : (useEid ? 'Add by eid failed' : 'User not found'),
                    ),
                    backgroundColor: sent ? AppTheme.successColor : AppTheme.warningColor,
                  ),
                );
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    ).then((_) {
      shortIdController.dispose();
      eidController.dispose();
    });
  }

  Future<void> _showOnlineUsersDialog() async {
    final user = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _OnlineUsersDialog(),
    );
    if (user != null && mounted) {
      _addOnlineUser(user);
    }
  }

  void _addOnlineUser(Map<String, dynamic> user) {
    final id = user['id'] as String? ?? '';
    final existing = id.isNotEmpty
        ? ref
            .read(friendsProvider)
            .where((f) => f.id.toLowerCase() == id.toLowerCase())
            .toList()
        : <Friend>[];
    if (existing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${existing.first.displayName} is already on '
              'your friend list'),
          backgroundColor: AppTheme.successColor,
        ),
      );
      return;
    }
    final shortId = user['short_id'] as String? ?? user['shortId'] as String? ?? '';
    ref.read(irohServiceProvider).sendFriendRequest(shortId);
    final name = user['name'] as String? ?? 'Unknown';
    _addPendingOutFriend(id: id, name: name, shortId: shortId);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Friend request sent!'),
        backgroundColor: AppTheme.successColor,
      ),
    );
  }

  // --- Friend management ------------------------------------------------

  void _showFriendOptions(Friend friend) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('Send Message'),
              onTap: () {
                Navigator.pop(context);
                _openChat(friend);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('Set Note'),
              subtitle: friend.note.isNotEmpty
                  ? Text(
                      '"${friend.note}" — shown instead of '
                      '${friend.name.trim().isNotEmpty ? friend.name : 'the peer name'}',
                    )
                  : null,
              onTap: () {
                Navigator.pop(context);
                _showEditNoteDialog(friend);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('View Profile'),
              subtitle: Text(
                '${friend.note.isNotEmpty && friend.name.trim().isNotEmpty ? '${friend.name}  ·  ' : ''}'
                '#${friend.shortId}',
              ),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: AppTheme.errorColor),
              title: const Text('Remove Friend', style: TextStyle(color: AppTheme.errorColor)),
              onTap: () {
                Navigator.pop(context);
                _confirmRemoveFriend(friend);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEditNoteDialog(Friend friend) {
    final controller = TextEditingController(text: friend.note);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set Note'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'A local note shown instead of this friend\u2019s name here. '
              'Only stored on this device.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 32,
              decoration: InputDecoration(
                hintText: 'e.g. John Doe',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onSubmitted: (_) {
                Navigator.pop(context);
                _saveNote(friend, controller.text.trim());
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _saveNote(friend, controller.text.trim());
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _saveNote(Friend friend, String note) {
    ref.read(friendsProvider.notifier).updateFriendNote(friend.id, note);
  }

  void _confirmRemoveFriend(Friend friend) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove Friend'),
        content: Text('Remove ${friend.displayName} from your friends?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorColor),
            onPressed: () {
              // Close the dialog synchronously, then remove on the side so the
              // async call below can never reference a closed dialog.
              Navigator.pop(dialogContext);
              unawaited(_removeFriend(friend));
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  Future<void> _removeFriend(Friend friend) async {
    await ref.read(irohServiceProvider).removeFriend(friend.id);
    if (mounted) {
      ref.read(friendsProvider.notifier).removeFriend(friend.id);
    }
  }
}

/// Browse registered online users and search by short ID, then add them.
class _OnlineUsersDialog extends ConsumerStatefulWidget {
  const _OnlineUsersDialog();

  @override
  ConsumerState<_OnlineUsersDialog> createState() => _OnlineUsersDialogState();
}

class _OnlineUsersDialogState extends ConsumerState<_OnlineUsersDialog> {
  final _searchController = TextEditingController();
  StreamSubscription<List<Map<String, dynamic>>>? _onlineUsersSub;
  List<Map<String, dynamic>> _onlineUsers = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadOnlineUsers();
  }

  @override
  void dispose() {
    _onlineUsersSub?.cancel();
    _onlineUsersSub = null;
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadOnlineUsers() async {
    setState(() => _isLoading = true);
    final iroh = ref.read(irohServiceProvider);

    _onlineUsersSub?.cancel();
    _onlineUsersSub = iroh.onlineUsersStream.listen((users) {
      if (mounted) {
        setState(() {
          _onlineUsers = users;
          _isLoading = false;
        });
      }
    });

    await iroh.listOnlineUsers();
    await Future.delayed(const Duration(seconds: 5));
    if (mounted && _isLoading) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _lookup() async {
    final shortId = _searchController.text.trim().replaceAll('#', '');
    if (shortId.isEmpty) return;

    setState(() => _isLoading = true);
    final iroh = ref.read(irohServiceProvider);
    try {
      final entry = await iroh.lookupUser(shortId);
      if (!mounted) return;
      setState(() => _isLoading = false);
      if (entry != null) {
        final peerHex = entry.id
            .fold('', (h, b) => '$h${b.toRadixString(16).padLeft(2, '0')}');
        Navigator.of(context).pop({
          'id': peerHex,
          'name': entry.name,
          'short_id': entry.shortId,
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('User not found'),
            backgroundColor: AppTheme.warningColor,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Browse Online Users',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search by short ID...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => _searchController.clear(),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                ),
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _lookup(),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: _isLoading && _onlineUsers.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _onlineUsers.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.explore_outlined,
                                  size: 48, color: AppTheme.textHint.withValues(alpha: 0.5)),
                              const SizedBox(height: 8),
                              const Text(
                                'No online users right now.\nTry the short-ID search above.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppTheme.textHint),
                              ),
                              const SizedBox(height: 12),
                              TextButton.icon(
                                onPressed: _loadOnlineUsers,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Refresh'),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: _onlineUsers.length,
                          itemBuilder: (context, index) {
                            final user = _onlineUsers[index];
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                                child: Text(
                                  user['name']?[0]?.toUpperCase() ?? '?',
                                  style: const TextStyle(
                                    color: AppTheme.primaryColor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              title: Text(
                                user['name'] ?? 'Unknown',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(
                                '#${user['short_id'] ?? user['shortId']}',
                                style: const TextStyle(color: AppTheme.textSecondary),
                              ),
                              trailing: ElevatedButton(
                                onPressed: () => Navigator.pop(context, user),
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                ),
                                child: const Text('Add'),
                              ),
                            );
                          },
                        ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Captures the microphone, decodes any nearby sound code and returns the
/// payload via [Navigator.pop] once heard (null on cancel / no result).
class _SoundListenDialog extends StatefulWidget {
  const _SoundListenDialog({required this.ultrasonic});

  final Ultrasonic ultrasonic;

  @override
  State<_SoundListenDialog> createState() => _SoundListenDialogState();
}

class _SoundListenDialogState extends State<_SoundListenDialog> {
  static const int _listenMs = 8000;

  bool _listening = false;
  String _status = '';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Listen for Sound Code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Tap "Start listening" FIRST, then have the other device play its '
            '"My Sound Code" — the code plays twice, so it is heard whenever '
            'it starts. Keep the microphone close to the other device\u2019s '
            'speaker. The chirp carries an offline friend request (via the '
            'shared relay).',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 16),
          _listening
              ? const SizedBox.square(
                  dimension: 48,
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                )
              : Icon(
                  Icons.waves,
                  size: 48,
                  color: AppTheme.primaryColor.withValues(alpha: 0.7),
                ),
          const SizedBox(height: 10),
          Text(
            _status,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 14),
          if (_listening)
            const LinearProgressIndicator()
          else
            FilledButton.icon(
              onPressed: _startListen,
              icon: const Icon(Icons.mic),
              label: const Text('Start listening'),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Future<void> _startListen() async {
    setState(() {
      _listening = true;
      _status = 'Listening… keep the two devices close together';
    });
    String? decoded;
    try {
      decoded = await widget.ultrasonic.listenAndDecode(durationMs: _listenMs);
    } catch (_) {
      decoded = null;
    }
    if (!mounted) return;
    if (decoded != null && decoded.isNotEmpty) {
      setState(() {
        _listening = false;
        _status = 'Heard a sound code';
      });
      Navigator.pop(context, decoded);
    } else {
      setState(() {
        _listening = false;
        _status = 'No valid code heard. Ask the other device to play its '
            '"Sound Code" again (try the audible band if it fell silent).';
      });
    }
  }
}