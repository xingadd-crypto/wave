import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_wave/models/friend.dart';
import 'package:flutter_wave/providers/app_provider.dart';
import 'package:flutter_wave/screens/moment_compose_screen.dart';
import 'package:flutter_wave/services/iroh_service.dart';
import 'package:flutter_wave/services/moments_store.dart';
import 'package:flutter_wave/theme/app_theme.dart';

/// Pull-based Moments timeline. Entering this screen (or pulling to refresh)
/// fetches each *online* friend's newer posts via `MomentFetch`, merges them
/// into the local cache and renders a single newest-first feed together with
/// my own posts. Images are lazy-loaded from the author on demand.
class MomentsScreen extends ConsumerStatefulWidget {
  const MomentsScreen({super.key});

  @override
  ConsumerState<MomentsScreen> createState() => _MomentsScreenState();
}

class _MomentsScreenState extends ConsumerState<MomentsScreen> {
  final IrohService _iroh = IrohService();
  StreamSubscription<String>? _events;

  List<_FeedItem> _items = [];
  bool _refreshing = false;
  bool _loadingMore = false;

  /// Bumped on every refresh so [_ImageGrid] re-checks its missing images even
  /// when the post id / imageCount are unchanged (old failed fetches get a
  /// second chance now that connectivity may be up).
  int _imageRetryKey = 0;

  Map<String, Friend> _friendsById() {
    final friends = ref.read(friendsProvider);
    return {for (final f in friends) f.id: f};
  }

  String get _myName {
    final n = ref.read(appStateProvider).nickname;
    return (n != null && n.trim().isNotEmpty) ? n : 'Me';
  }

  String get _myHex => _iroh.currentIdentity?.publicKeyHex ?? '';

  @override
  void initState() {
    super.initState();
    _events = _iroh.momentEventStream.listen((_) {
      if (mounted) {
        _reload();
        _ensureVisibleImages();
      }
    });
    // Show whatever is already cached immediately — no network wait on entry.
    _reload();
    Future.microtask(_refresh);
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  /// Rebuilds the merged timeline from local caches.
  void _reload() {
    final friends = _friendsById();
    final myName = _myName;
    final futures = <Future<List<_FeedItem>>>[];

    for (final f in friends.values.where((f) => f.status == FriendStatus.accepted)) {
      futures.add(MomentsStore.loadFriendMoments(f.id).then((list) => [
            for (final p in list)
              _FeedItem(
                authorHex: f.id,
                authorName:
                    f.displayName.isNotEmpty ? f.displayName : f.name,
                isMine: false,
                post: p,
                friend: f,
              ),
          ]));
    }
    futures.add(MomentsStore.loadMyMoments().then((list) => [
          for (final p in list)
            _FeedItem(
              authorHex: _myHex,
              authorName: myName,
              isMine: true,
              post: p,
            ),
        ]));

    Future.wait(futures).then((groups) {
      if (!mounted) return;
      final items = <_FeedItem>[...groups.expand((g) => g)]
        ..sort((a, b) =>
            (b.post['ts'] as int? ?? 0).compareTo(a.post['ts'] as int? ?? 0));
      setState(() => _items = items);
    });
  }

  /// Pulls new posts from every currently-online friend (presence probes are
  /// refreshed first), then reloads the merged feed. Fetches run in small
  /// batches and the friend set is capped so a phone with many online friends
  /// doesn't fire hundreds of round-trips at once; the cursor-based merge means
  /// whoever is skipped this round is caught on the next refresh.
  static const int _refreshFriendLimit = 20;
  static const int _fetchConcurrency = 4;
  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await ref.read(friendsProvider.notifier).probePresence();
      if (!mounted) return;
      setState(() {});
      final friends = ref.read(friendsProvider);
      // Use the persisted isOnline flag (preserved for backed-off friends)
      // rather than the probe return value, which only covers resolved friends.
      final online = <Friend>[];
      for (final f in friends) {
        if (f.status != FriendStatus.accepted) continue;
        if (f.isOnline) online.add(f);
      }
      final capped = online.take(_refreshFriendLimit).toList();
      for (var i = 0; i < capped.length; i += _fetchConcurrency) {
        final slice = capped.skip(i).take(_fetchConcurrency).toList();
        await Future.wait(slice.map((f) => _iroh.fetchFriendMoments(f)));
      }
      unawaited(MomentsStore.pruneOrphanedImages(_myHex));
      if (mounted) setState(() => _imageRetryKey++);
    } finally {
      _refreshing = false;
    }
  }

  /// Paged pull of older posts for every online friend.
  Future<void> _loadMore() async {
    if (_loadingMore) return;
    _loadingMore = true;
    try {
      final friends = ref.read(friendsProvider);
      final online = friends.where((f) =>
          f.status == FriendStatus.accepted && f.isOnline).toList();
      final oldest = _items.where((i) => !i.isMine).fold<int?>(null, (m, i) {
        final ts = i.post['ts'] as int?;
        return ts == null ? m : (m == null || ts < m ? ts : m);
      });
      final capped = online.take(_refreshFriendLimit).toList();
      for (var i = 0; i < capped.length; i += _fetchConcurrency) {
        final slice = capped.skip(i).take(_fetchConcurrency).toList();
        await Future.wait(slice.map((f) => _iroh.fetchFriendMoments(f, before: oldest)));
      }
      unawaited(MomentsStore.pruneOrphanedImages(_myHex));
      if (mounted) setState(() {});
    } finally {
      _loadingMore = false;
    }
  }

  /// Fetches (up to [max]) missing images of the newest posts so thumbnails
  /// appear without waiting for a tap.
  void _ensureVisibleImages() {
    for (final item in _items) {
      final count = item.post['imageCount'] as int? ?? 0;
      for (var i = 0; i < count; i++) {
        final owner = item.authorHex;
        MomentsStore.imageExists(owner, item.post['id'] as String? ?? '', i)
            .then((exists) {
          if (!exists) {
            unawaited(_iroh.fetchMomentImage(
                item.authorHex, item.post['id'] as String? ?? '', i,
                authorHex: owner));
          }
        });
      }
    }
  }

  Future<void> _openCompose() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const MomentComposeScreen()),
    );
    if (!mounted) return;
    _reload();
    _ensureVisibleImages();
  }

  Future<void> _toggleLike(_FeedItem item) async {
    if (item.isMine || item.friend == null) return;
    await _iroh.sendMomentReact(item.friend!, item.post['id'] as String,
        1);
    if (mounted) _reload();
  }

  Future<void> _addComment(_FeedItem item) async {
    final textCtrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Comment'),
        content: TextField(
          controller: textCtrl,
          autofocus: true,
          maxLength: 200,
          decoration: const InputDecoration(hintText: 'Write a comment…'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(textCtrl.text.trim()),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    textCtrl.dispose();
    if (text == null || text.isEmpty) return;
    if (item.isMine) return;
    await _iroh.sendMomentReact(
        item.friend!, item.post['id'] as String, 2,
        text: text);
    if (mounted) _reload();
  }

  /// The author replies to a comment on their own post. The comment's source
  /// hex identifies the commenter; a reply is sent to them (and also recorded
  /// locally with the thread reference).
  Future<void> _replyToComment(_FeedItem item, Map<String, dynamic> comment) async {
    if (!item.isMine) return;
    final commenterHex = comment['hex'] as String? ?? '';
    final commenter = _friendsById()[commenterHex];
    if (commenter == null) return;
    final textCtrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reply'),
        content: TextField(
          controller: textCtrl,
          autofocus: true,
          maxLength: 200,
          decoration: const InputDecoration(hintText: 'Write a reply…'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(textCtrl.text.trim()),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    textCtrl.dispose();
    if (text == null || text.isEmpty) return;
    final commenterName =
        commenter.displayName.isNotEmpty ? commenter.displayName : commenter.name;
    await _iroh.sendMomentReply(
      commenter,
      item.post['id'] as String,
      text,
      replyToTs: comment['ts'] as int? ?? 0,
      replyToName: commenterName,
    );
    if (mounted) _reload();
  }

  Future<void> _deleteMoment(_FeedItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete'),
        content: const Text('Delete this post?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _iroh.deleteMyMoment(item.post['id'] as String);
      if (mounted) _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.primaryColor,
        foregroundColor: Colors.white,
        title: const Text('Moments'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'New post',
            onPressed: _openCompose,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _items.isEmpty && _refreshing
            ? const Center(child: CircularProgressIndicator())
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(8),
                itemCount: _items.length + 1,
                itemBuilder: (context, index) {
                  if (index == _items.length) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: TextButton(
                          onPressed: _loadMore,
                          child: const Text('Load older'),
                        ),
                      ),
                    );
                  }
                  final item = _items[index];
                  return _MomentCard(
                    item: item,
                    friendsById: _friendsById(),
                    myHex: _myHex,
                    retryKey: _imageRetryKey,
                    onLike: () => _toggleLike(item),
                    onComment: () => _addComment(item),
                    onReply: (c) => _replyToComment(item, c),
                    onDelete: item.isMine ? () => _deleteMoment(item) : null,
                  );
                },
              ),
      ),
    );
  }
}

class _FeedItem {
  final String authorHex;
  final String authorName;
  final bool isMine;
  final Map<String, dynamic> post;
  final Friend? friend;

  _FeedItem({
    required this.authorHex,
    required this.authorName,
    required this.isMine,
    required this.post,
    this.friend,
  });
}

class _MomentCard extends StatelessWidget {
  final _FeedItem item;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback? onDelete;
  final Map<String, Friend> friendsById;
  final String myHex;
  final ValueChanged<Map<String, dynamic>>? onReply;
  final int retryKey;

  const _MomentCard({
    required this.item,
    required this.onLike,
    required this.onComment,
    required this.friendsById,
    required this.myHex,
    this.onReply,
    this.onDelete,
    this.retryKey = 0,
  });

  @override
  Widget build(BuildContext context) {
    final post = item.post;
    final imageCount = (post['imageCount'] as int? ?? 0).clamp(0, 9).toInt();
    final likes = (post['likes'] as List?)?.length ?? 0;
    final myLike = post['myLike'] == true;
    // My posts: `comments` holds received comments from friends.
    final comments = (post['comments'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    // Friend posts: `myComments` holds the comments I sent.
    final myComments = (post['myComments'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];

    final commentCount = comments.length + myComments.length;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.15),
                  child: Text(
                    item.authorName.isNotEmpty
                        ? item.authorName.characters.first.toUpperCase()
                        : '?',
                    style: const TextStyle(
                        color: AppTheme.primaryColor,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.authorName,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(_formatTs(post['ts'] as int? ?? 0),
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
                if (onDelete != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: onDelete,
                  ),
              ],
            ),
            if ((post['text'] as String? ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(post['text'] as String? ?? ''),
            ],
            if (imageCount > 0) ...[
              const SizedBox(height: 10),
              _ImageGrid(
                authorHex: item.authorHex,
                postId: post['id'] as String? ?? '',
                imageCount: imageCount,
                retryKey: retryKey,
              ),
            ],
            const SizedBox(height: 8),
            if (!item.isMine)
              Row(
                children: [
                  _ActionButton(
                    icon: myLike ? Icons.favorite : Icons.favorite_border,
                    color: myLike ? Colors.redAccent : null,
                    label: myLike ? 'Liked' : 'Like',
                    onTap: onLike,
                  ),
                  _ActionButton(
                    icon: Icons.comment_outlined,
                    label: 'Comment',
                    onTap: onComment,
                  ),
                ],
              )
            else
              Row(
                children: [
                  if (likes > 0)
                    _ActionButton(
                        icon: Icons.favorite, label: '$likes likes', onTap: () {}),
                  if (commentCount > 0)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Text(
                          '$commentCount comments',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ),
                    ),
                ],
              ),
            if (comments.isNotEmpty || myComments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // On my own posts I can reply to each comment.
                    for (final c in comments)
                      _CommentRow(
                        name: _nameForComment(c),
                        comment: c,
                        isMine: false,
                        replyToName: c['replyToName'] as String?,
                        onReply: item.isMine
                            ? () => onReply?.call(c)
                            : null,
                      ),
                    for (final c in myComments)
                      _CommentRow(
                          name: 'You', comment: c, isMine: true),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _nameForComment(Map<String, dynamic> c) {
    final hex = c['hex'] as String? ?? '';
    // The author's own reply is shown as "You".
    if (hex.isNotEmpty && hex.toLowerCase() == myHex.toLowerCase()) {
      return 'You';
    }
    if (hex.isNotEmpty) {
      final f = friendsById[hex];
      if (f != null) return f.displayName.isNotEmpty ? f.displayName : f.name;
    }
    return 'Friend';
  }
}

/// Renders one comment line: "<name>: <text>". Comments are stored as
/// `{hex, text, ts}` on my posts and `{text, ts}` on friend posts. Author
/// replies additionally carry `replyTo`/`replyToName` and are shown as
/// "<name> 回复 <replyToName>: <text>". [onReply] adds a small "Reply"
/// affordance (used by the author on their own post).
class _CommentRow extends StatelessWidget {
  final String name;
  final Map<String, dynamic> comment;
  final bool isMine;
  final String? replyToName;
  final VoidCallback? onReply;

  const _CommentRow({
    required this.name,
    required this.comment,
    required this.isMine,
    this.replyToName,
    this.onReply,
  });

  @override
  Widget build(BuildContext context) {
    final text = comment['text'] as String? ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name,
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: AppTheme.primaryColor)),
          if (replyToName != null && replyToName!.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text('回复 $replyToName',
                style: TextStyle(
                    fontSize: 12, color: Colors.grey.shade600)),
          ],
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
            ),
          ),
          if (onReply != null)
            InkWell(
              onTap: onReply,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text('Reply',
                    style: TextStyle(
                        fontSize: 11, color: Colors.blueGrey.shade600)),
              ),
            ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 4),
            Text(label,
                style:
                    TextStyle(fontSize: 13, color: color ?? Colors.grey.shade700)),
          ],
        ),
      ),
    );
  }
}

/// Lazy image grid: cached files render instantly, missing cells trigger a
/// fetch and rebuild once the bytes arrive (via [IrohService.momentEventStream]).
class _ImageGrid extends ConsumerStatefulWidget {
  final String authorHex;
  final String postId;
  final int imageCount;
  final int retryKey;

  const _ImageGrid({
    required this.authorHex,
    required this.postId,
    required this.imageCount,
    this.retryKey = 0,
  });

  @override
  ConsumerState<_ImageGrid> createState() => _ImageGridState();
}

class _ImageGridState extends ConsumerState<_ImageGrid> {
  final Map<int, bool> _missing = {};

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.imageCount; i++) {
      _check(i);
    }
  }

  @override
  void didUpdateWidget(_ImageGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.retryKey != widget.retryKey ||
        oldWidget.postId != widget.postId ||
        oldWidget.imageCount != widget.imageCount) {
      _missing.clear();
      for (var i = 0; i < widget.imageCount; i++) {
        _check(i);
      }
    }
  }

  void _check(int i) {
    MomentsStore.imageExists(widget.authorHex, widget.postId, i)
        .then((exists) {
      if (!exists) {
        if (mounted) setState(() => _missing[i] = true);
        unawaited(IrohService()
            .fetchMomentImage(widget.authorHex, widget.postId, i,
                authorHex: widget.authorHex)
            .then((_) {
          if (mounted) setState(() => _missing.remove(i));
        }));
      }
    });
  }

  int _columns() {
    if (widget.imageCount == 1) return 1;
    if (widget.imageCount == 4) return 2;
    return widget.imageCount >= 6 ? 3 : 2;
  }

  @override
  Widget build(BuildContext context) {
    final columns = _columns();
    final size = (MediaQuery.of(context).size.width - 8 * 2 - 24 * 2) / columns;
    return GridView.count(
      crossAxisCount: columns,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      childAspectRatio: 1,
      children: [
        for (var i = 0; i < widget.imageCount; i++)
          FutureBuilder<bool>(
            future: MomentsStore.imageExists(widget.authorHex, widget.postId, i),
            builder: (context, snap) {
              final exists = snap.data ?? false;
              if (exists) {
                return FutureBuilder(
                  future: MomentsStore.imageFile(widget.authorHex, widget.postId, i),
                  builder: (context, fs) => ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: fs.hasData
                        ? Image.file(fs.data as File,
                            width: size, height: size, fit: BoxFit.cover)
                        : const SizedBox(),
                  ),
                );
              }
              return ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  color: Colors.black12,
                  child: Center(
                    child: _missing[i] == true
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.image_outlined, color: Colors.black26),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

String _formatTs(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${dt.month}-${dt.day}';
}