import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_wave/theme/app_theme.dart';
import 'package:flutter_wave/models/friend.dart';
import 'package:flutter_wave/providers/app_provider.dart';
import 'package:flutter_wave/widgets/chat_list_item.dart';
import 'package:flutter_wave/screens/chat_screen.dart';

class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  @override
  void initState() {
    super.initState();
    // Refresh presence only when the user actually views the chat list.
    ref.read(friendsProvider.notifier).probePresence();
  }

  @override
  Widget build(BuildContext context) {
    final friends = ref.watch(friendsProvider);
    final activeFriends = friends.where((f) => f.status == FriendStatus.accepted).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Wave',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showNewChatDialog,
          ),
        ],
      ),
      body: activeFriends.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              itemCount: activeFriends.length,
              itemBuilder: (context, index) {
                final friend = activeFriends[index];
                return ChatListItem(
                  friend: friend,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatScreen(friend: friend),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline, size: 80, color: AppTheme.textHint.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(
            'No conversations yet',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            'Start a chat by adding friends',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppTheme.textHint),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _showNewChatDialog,
            icon: const Icon(Icons.add),
            label: const Text('Start Chat'),
          ),
        ],
      ),
    );
  }

  void _showNewChatDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _NewChatSheet(),
    );
  }
}

class _NewChatSheet extends ConsumerStatefulWidget {
  @override
  ConsumerState<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends ConsumerState<_NewChatSheet> {
  final _shortIdController = TextEditingController();
  bool _isLooking = false;
  Map<String, dynamic>? _foundUser;

  @override
  void dispose() {
    _shortIdController.dispose();
    super.dispose();
  }

  Future<void> _lookupUser() async {
    final shortId = _shortIdController.text.trim().replaceAll('#', '');
    if (shortId.isEmpty) return;

    setState(() => _isLooking = true);
    final iroh = ref.read(irohServiceProvider);
    try {
      final entry = await iroh.lookupUser(shortId);
      if (!mounted) return;
      setState(() {
        if (entry != null) {
          _foundUser = {
            'id': entry.id
                .fold('', (h, b) => '$h${b.toRadixString(16).padLeft(2, '0')}'),
            'name': entry.name,
            'short_id': entry.shortId,
          };
        } else {
          _foundUser = null;
        }
        _isLooking = false;
      });
    } finally {
      if (mounted) setState(() => _isLooking = false);
    }
  }

  void _startChat() {
    if (_foundUser == null) return;

    final id = _foundUser!['id'] as String? ?? '';
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That user cannot be contacted (missing endpoint id).'),
          backgroundColor: AppTheme.warningColor,
        ),
      );
      return;
    }
    final shortId = _foundUser!['short_id'] as String? ?? '';
    final name = _foundUser!['name'] as String? ?? 'Unknown';

    final friends = ref.read(friendsProvider);
    final existing =
        friends.where((f) => f.id.toLowerCase() == id.toLowerCase()).firstOrNull;

    final chatFriend = existing ??
        Friend(
          id: id,
          name: name,
          shortId: shortId,
          status: FriendStatus.accepted,
          createdAt: DateTime.now(),
        );

    if (existing == null) {
      ref.read(friendsProvider.notifier).addFriend(chatFriend);
    }

    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatScreen(friend: chatFriend)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('New Chat', style: Theme.of(context).textTheme.headlineSmall),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _shortIdController,
                      decoration: const InputDecoration(
                        labelText: 'Short ID',
                        hintText: 'e.g. 10001',
                        prefixIcon: Icon(Icons.tag),
                      ),
                      keyboardType: TextInputType.number,
                      onSubmitted: (_) => _lookupUser(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: _isLooking
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.search),
                    onPressed: _isLooking ? null : _lookupUser,
                  ),
                ],
              ),
              if (_foundUser != null) ...[
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                      child: Text(
                        _foundUser!['name']?[0]?.toUpperCase() ?? '?',
                        style: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold),
                      ),
                    ),
                    title: Text(_foundUser!['name'] ?? 'Unknown'),
                    subtitle: Text('#${_foundUser!['short_id']}'),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _startChat,
                  child: const Text('Start Chat'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
