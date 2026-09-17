import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_wave/models/app_state.dart';
import 'package:flutter_wave/models/friend.dart';
import 'package:flutter_wave/models/message.dart';
import 'package:flutter_wave/models/file_transfer.dart';
import 'package:flutter_wave/services/iroh_service.dart';
import 'package:flutter_wave/services/persistence_service.dart';
import 'package:flutter_wave/services/email_vault_service.dart';

final appStateProvider = StateNotifierProvider<AppStateNotifier, AppState>((ref) {
  return AppStateNotifier();
});

class AppStateNotifier extends StateNotifier<AppState> {
  final IrohService _irohService = IrohService();

  AppStateNotifier() : super(AppState());

  IrohService get irohService => _irohService;

  Future<void> initialize() async {
    final savedTheme = await PersistenceService.loadThemeMode();
    final themeMode = savedTheme == 'dark'
        ? ThemeMode.dark
        : savedTheme == 'light'
            ? ThemeMode.light
            : ThemeMode.system;

    final hasIdentity = await _irohService.initialize();
    if (hasIdentity) {
      final identity = _irohService.currentIdentity;
      if (identity != null) {
        state = state.copyWith(
          isInitialized: true,
          isRegistered: identity.shortId != null,
          nickname: identity.nickname,
          userId: identity.publicKeyHex,
          shortId: identity.shortId,
          serverAddress: identity.serverAddress,
          themeMode: themeMode,
        );
      }
    } else {
      state = state.copyWith(isInitialized: false, themeMode: themeMode);
    }
  }

  Future<bool> register(String nickname, String serverAddress) async {
    await _irohService.identityManager.createIdentity(nickname, serverAddress: serverAddress);
    final identity = _irohService.currentIdentity;

    state = state.copyWith(
      isInitialized: true,
      isRegistered: true,
      nickname: nickname,
      userId: identity?.publicKeyHex,
      serverAddress: serverAddress,
    );

    return true;
  }

  Future<bool> connectToServer() async {
    final connected = await _irohService.connectAndRegister();
    if (connected) {
      final identity = _irohService.currentIdentity;
      state = state.copyWith(
        isConnected: true,
        shortId: identity?.shortId,
      );
    }
    return connected;
  }

  Future<void> updateNickname(String newName, {List<Friend> friends = const []}) async {
    await _irohService.updateNickname(newName);
    await _irohService.sendNicknameChange(newName, friends);
    state = state.copyWith(nickname: newName);
  }

  void updateServerAddress(String newAddress) {
    state = state.copyWith(serverAddress: newAddress);
  }

  void toggleTheme() {
    final newMode = state.themeMode == ThemeMode.light
        ? ThemeMode.dark
        : ThemeMode.light;
    state = state.copyWith(themeMode: newMode);
    PersistenceService.saveThemeMode(newMode == ThemeMode.dark ? 'dark' : 'light');
  }
}

final friendsProvider = StateNotifierProvider<FriendsNotifier, List<Friend>>((ref) {
  return FriendsNotifier();
});

class FriendsNotifier extends StateNotifier<List<Friend>> {
  FriendsNotifier() : super([]);

  /// Coalesces bursts of mutations (unread ticks, presence flips, status
  /// updates) into a single persistence write 300 ms after the last change.
  static const Duration _saveDebounce = Duration(milliseconds: 300);
  Timer? _saveTimer;
  bool _savePending = false;

  Future<void> initialize() async {
    final friends = await PersistenceService.loadFriends();
    state = friends;
    pruneStalePending();
  }

  /// Removes pending-out entries that have not been accepted within [maxAge]
  /// (default 7 days). Pending-in requests are kept — the user still decides on
  /// those. No-ops when nothing is stale.
  void pruneStalePending({Duration maxAge = const Duration(days: 7)}) {
    final cutoff = DateTime.now().subtract(maxAge);
    final pruned = state.where((f) =>
        !(f.status == FriendStatus.pendingOut &&
            f.createdAt.isBefore(cutoff))).toList();
    if (pruned.length == state.length) return;
    state = pruned;
    _save();
  }

  void addFriend(Friend friend) {
    final existingIndex = state.indexWhere((f) => f.id == friend.id);
    if (existingIndex >= 0) {
      final existing = state[existingIndex];
      final merged = Friend(
        id: existing.id,
        name: friend.name.isNotEmpty ? friend.name : existing.name,
        shortId: friend.shortId.isNotEmpty ? friend.shortId : existing.shortId,
        status: existing.status,
        createdAt: existing.createdAt,
      );
      final updated = [...state];
      updated[existingIndex] = merged;
      state = updated;
    } else {
      state = [...state, friend];
    }
    _save();
  }

  void updateFriend(Friend updatedFriend) {
    state = [
      for (final friend in state)
        if (friend.id == updatedFriend.id) updatedFriend else friend,
    ];
    _save();
  }

  void removeFriend(String friendId) {
    state = state.where((f) => f.id != friendId).toList();
    _save();
  }

  void updateFriendName(String friendId, String newName) {
    state = [
      for (final friend in state)
        if (friend.id == friendId) friend.copyWith(name: newName) else friend,
    ];
    _save();
  }

  /// Sets (or clears, when [note] is empty) the local note for a friend.
  void updateFriendNote(String friendId, String note) {
    state = [
      for (final friend in state)
        if (friend.id == friendId) friend.copyWith(note: note) else friend,
    ];
    _save();
  }

  /// Marks each friend online/offline based on the set of currently-online
  /// ids fetched from the Moon server. A friend is considered online when
  /// either its eid or its short id appears in [onlineIds].
  void updatePresence(Iterable<String> onlineIds) {
    final ids = onlineIds.toSet();
    state = [
      for (final friend in state)
        if (ids.contains(friend.id) || (friend.shortId.isNotEmpty && ids.contains(friend.shortId)))
          friend.copyWith(isOnline: true)
        else
          friend.copyWith(isOnline: false),
    ];
    _save();
  }

  void setFriendOnline(String friendId, bool online) {
    state = [
      for (final friend in state)
        if (friend.id == friendId)
          friend.copyWith(isOnline: online)
        else
          friend,
    ];
  }

/// Records the app version + platform a friend announced via presence.
  /// Transient like online state (no persist) — refreshed on every probe round.
  void updateFriendVersion(String friendId, String version, {String? platform}) {
    state = [
      for (final friend in state)
        if (friend.id == friendId)
          friend.copyWith(
            version: version.trim().isEmpty ? null : version.trim(),
            platform: (platform == null || platform.trim().isEmpty)
                ? null
                : platform.trim(),
          )
        else
          friend,
    ];
  }

  /// Probes every accepted friend over P2P to determine online status,
  /// replacing the old dependency on the Moon server's `listOnlineUsers`.
  /// `probeFriendsPresence` only reports friends actually resolved this round
  /// (backed-off friends stay unresolved); friends not in [presence] keep their
  /// last-known state instead of being flipped to offline.
  bool _probeInFlight = false;
  Future<Set<String>> probePresence() async {
    if (_probeInFlight) return const {};
    _probeInFlight = true;
    try {
      final iroh = IrohService();
      final accepted =
          state.where((f) => f.status == FriendStatus.accepted).toList();
      final presence = await iroh.probeFriendsPresence(accepted);
      state = [
        for (final friend in state)
          if (presence.containsKey(friend.id))
            friend.copyWith(isOnline: presence[friend.id]!)
          else if (friend.shortId.isNotEmpty &&
              presence.containsKey(friend.shortId))
            friend.copyWith(isOnline: presence[friend.shortId]!)
          else
            friend,
      ];
      final onlineIds = presence.entries
          .where((e) => e.value)
          .map((e) => e.key)
          .toSet();
      for (final id in onlineIds) {
        unawaited(iroh.notifyFriendOnline(id));
      }
      return onlineIds;
    } finally {
      _probeInFlight = false;
    }
  }

  void updateLastMessage(String friendId, String message, DateTime time) {
    state = [
      for (final friend in state)
        if (friend.id == friendId)
          friend.copyWith(lastMessage: message, lastMessageTime: time)
        else
          friend,
    ];
    _save();
  }

  void incrementUnread(String friendId) {
    state = [
      for (final friend in state)
        if (friend.id == friendId)
          friend.copyWith(unreadCount: friend.unreadCount + 1)
        else
          friend,
    ];
    _save();
  }

  void clearUnread(String friendId) {
    state = [
      for (final friend in state)
        if (friend.id == friendId)
          friend.copyWith(unreadCount: 0)
        else
          friend,
    ];
    _save();
  }

  /// Replaces the whole friend list with a cloud-merged result (from the email
  /// vault). Persists without triggering a debounce re-push.
  void applySyncedFriends(List<Friend> merged) {
    state = merged;
    PersistenceService.saveFriends(state);
  }

  void _save() {
    _savePending = true;
    _saveTimer ??= Timer(_saveDebounce, () {
      _saveTimer = null;
      if (!_savePending) return;
      _savePending = false;
      PersistenceService.saveFriends(state);
      unawaited(_autoPushSnapshot());
    });
  }

  /// Queues an email-vault push of the current friends when a synced mailbox
  /// is configured on this device.
  Future<void> _autoPushSnapshot() async {
    final identity = IrohService().currentIdentity;
    EmailVaultService.instance.scheduleAutoPush(
      identity: identity?.toJson(),
      friends: List.of(state),
    );
  }
}

final messagesProvider = StateNotifierProvider.family<MessagesNotifier, List<Message>, String>((ref, chatId) {
  return MessagesNotifier(chatId);
});

class MessagesNotifier extends StateNotifier<List<Message>> {
  final String _chatId;

  /// Coalesces bursts (incoming message + played + status) into a single
  /// persistence write 300 ms after the last change.
  static const Duration _saveDebounce = Duration(milliseconds: 300);
  Timer? _saveTimer;
  bool _savePending = false;

  MessagesNotifier(this._chatId) : super([]) {
    _loadMessages();
  }

  Future<void> _loadMessages() async {
    try {
      final messages = await PersistenceService.loadMessages(_chatId);
      if (mounted) {
        final current = state;
        if (current.isEmpty) {
          state = messages;
        } else {
          // Merge so messages added while the async load was in flight are
          // not clobbered by the (older) persisted snapshot.
          final currentIds = {for (final m in current) m.id};
          state = [
            for (final m in messages)
              if (!currentIds.contains(m.id)) m,
            ...current,
          ];
        }
      }
    } catch (_) {
      if (mounted) state = [];
    }
  }

  void addMessage(Message message) {
    if (state.any((m) => m.id == message.id)) return;
    state = [...state, message];
    _save();
  }

  void updateMessageStatus(String messageId, MessageStatus status) {
    state = [
      for (final msg in state)
        if (msg.id == messageId) msg.copyWith(status: status) else msg,
    ];
    _save();
  }

  void markPlayed(String messageId) {
    state = [
      for (final msg in state)
        if (msg.id == messageId) msg.copyWith(played: true) else msg,
    ];
    _save();
  }

  void clearMessages() {
    state = [];
    _save();
  }

  void _save() {
    _savePending = true;
    _saveTimer ??= Timer(_saveDebounce, () {
      _saveTimer = null;
      if (!_savePending) return;
      _savePending = false;
      PersistenceService.saveMessages(_chatId, state);
    });
  }
}

final selectedChatProvider = StateProvider<String?>((ref) => null);

final onlineUsersProvider = StateProvider<List<Map<String, dynamic>>>((ref) => []);

final irohServiceProvider = Provider<IrohService>((ref) {
  return IrohService();
});

final activeChatIdProvider = StateProvider<String?>((ref) => null);

final fileTransfersProvider =
    StateProvider<Map<String, FileTransferProgress>>((ref) => {});

