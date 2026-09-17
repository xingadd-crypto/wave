enum FriendStatus { pendingOut, pendingIn, accepted }

class Friend {
  final String id;
  final String name;
  final String shortId;
  final FriendStatus status;
  final DateTime createdAt;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final int unreadCount;
  final bool isOnline;

  /// App version the friend announced via the P2P presence handshake.
  /// Transient like [isOnline] — never persisted, refreshed on each probe.
  final String? version;

  /// Platform the friend's build runs on ('android'|'windows' or null when the
  /// peer predates version negotiation). Transient like [version]. Each build
  /// only serves its own platform's update packages.
  final String? platform;

  /// Local note (备注) set by the user on this device. Empty when unset.
  /// Displayed with priority over the peer-reported [name].
  final String note;

  Friend({
    required this.id,
    required this.name,
    required this.shortId,
    required this.status,
    required this.createdAt,
    this.lastMessage,
    this.lastMessageTime,
    this.unreadCount = 0,
    this.isOnline = false,
    this.version,
    this.platform,
    this.note = '',
  });

  /// Display name for chat: prefer the local note, then nickname, then short
  /// id, then fall back to the full eid (id) so an eid-added friend still
  /// shows something sensible.
  String get displayName {
    if (note.trim().isNotEmpty) return note;
    if (name.trim().isNotEmpty) return name;
    if (shortId.trim().isNotEmpty) return shortId;
    return id;
  }

  /// Secondary label shown under the display name (currently just the short id).
  String get secondaryLabel {
    if (shortId.trim().isNotEmpty) return shortId;
    return '';
  }

  Friend copyWith({
    String? id,
    String? name,
    String? shortId,
    FriendStatus? status,
    DateTime? createdAt,
    String? lastMessage,
    DateTime? lastMessageTime,
    int? unreadCount,
    bool? isOnline,
    String? version,
    String? platform,
    String? note,
  }) {
    return Friend(
      id: id ?? this.id,
      name: name ?? this.name,
      shortId: shortId ?? this.shortId,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      isOnline: isOnline ?? this.isOnline,
      version: version ?? this.version,
      platform: platform ?? this.platform,
      note: note ?? this.note,
    );
  }
}
