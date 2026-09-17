import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:iroh_flutter/iroh_flutter.dart';
import 'package:flutter_wave/models/message.dart';
import 'package:flutter_wave/models/friend.dart';
import 'package:flutter_wave/models/file_transfer.dart';
import 'package:flutter_wave/services/identity_manager.dart';
import 'package:flutter_wave/services/postcard.dart';
import 'package:flutter_wave/services/image_message_io.dart';
import 'package:flutter_wave/services/persistence_service.dart';
import 'package:flutter_wave/services/moments_store.dart';
import 'package:flutter_wave/services/g711.dart';
import 'package:flutter_wave/services/call_audio_io.dart';
import 'package:flutter_wave/services/app_version.dart';
import 'package:flutter_wave/services/update_service.dart';
import 'package:flutter_wave/config.dart';
import 'package:blake3_dart/blake3_dart.dart';
import 'package:path_provider/path_provider.dart';

class IrohService {
  static final IrohService _instance = IrohService._internal();
  factory IrohService() => _instance;
  IrohService._internal();

  final IdentityManager _identityManager = IdentityManager();
  IdentityManager get identityManager => _identityManager;

  final StreamController<Message> _messageController =
      StreamController<Message>.broadcast();
  final StreamController<Friend> _friendRequestController =
      StreamController<Friend>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  final StreamController<List<Map<String, dynamic>>> _onlineUsersController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final StreamController<Map<String, dynamic>?> _lookupResultController =
      StreamController<Map<String, dynamic>?>.broadcast();
  final StreamController<String> _incomingMessageController =
      StreamController<String>.broadcast();
  final StreamController<FileTransferProgress> _fileTransferController =
      StreamController<FileTransferProgress>.broadcast();
  final StreamController<FileDownloaded> _fileDownloadController =
      StreamController<FileDownloaded>.broadcast();
  final StreamController<IncomingFileOffer> _incomingFileController =
      StreamController<IncomingFileOffer>.broadcast();

  /// Pending (unresolved) accept/reject + save-location decisions for inbound
  /// file offers, keyed by fileId. Set by [respondIncomingFile] from the UI.
  final Map<String, Completer<bool>> _fileDecisions = {};
  final Map<String, String> _fileDecisionPath = {};
  static const Duration _fileDecisionTimeout = Duration(seconds: 120);

  Stream<Message> get messageStream => _messageController.stream;
  Stream<Friend> get friendRequestStream => _friendRequestController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  Stream<String> get statusStream => _statusController.stream;
  Stream<List<Map<String, dynamic>>> get onlineUsersStream =>
      _onlineUsersController.stream;
  Stream<Map<String, dynamic>?> get lookupResultStream =>
      _lookupResultController.stream;
  Stream<String> get incomingMessageStream => _incomingMessageController.stream;
  Stream<FileTransferProgress> get fileTransferStream =>
      _fileTransferController.stream;
  Stream<FileDownloaded> get fileDownloadStream =>
      _fileDownloadController.stream;
  Stream<IncomingFileOffer> get incomingFileStream =>
      _incomingFileController.stream;

  // 鈹€鈹€ Moments (pull-based social feed) 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

  /// Broadcasts a lightweight event every time moment state changed, so the
  /// UI can reload its caches from disk. Topic strings:
  ///   - 'me' or a friend hex 鈫?the feed cache changed
  ///   - 'image:<post>:<index>' 鈫?an image byte arrived
  ///   - 'react:<post>:<type>:<hex>' 鈫?someone liked/commented my post
  final StreamController<String> _momentEventController =
      StreamController<String>.broadcast();
  Stream<String> get momentEventStream => _momentEventController.stream;

  void _emitMomentEvent(String topic) {
    if (!_momentEventController.isClosed) {
      _momentEventController.add(topic);
    }
  }

  static const int _momentMaxImages = 9;

  /// Per-image cap for inbound moment images (posts are compacted to 鈮?512 KB
  /// on publish, so this is a generous ceiling against disk-fill).
  static const int _momentImageMaxBytes = 4 * 1024 * 1024;

  // 鈹€鈹€ Voice call 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

  final StreamController<CallEvent> _callEventController =
      StreamController<CallEvent>.broadcast();
  final StreamController<IncomingCall> _incomingCallController =
      StreamController<IncomingCall>.broadcast();

  Stream<CallEvent> get callEventStream => _callEventController.stream;
  Stream<IncomingCall> get incomingCallStream => _incomingCallController.stream;

  CallPhase _callPhase = CallPhase.idle;
  String? _callId;
  String? _callPeerName;
  String? _callPeerShortId;
  SendStream? _callTx;
  RecvStream? _callRx;
  bool _callLocalHangup = false;
  bool _callConnected = false;
  CallAudioIO? _callAudio;
  int _callSeq = 0;
  Completer<bool>? _incomingAnswer;

  bool get isInCall => _callPhase != CallPhase.idle;
  bool get isCallBusy => _callConnected;

  bool _isConnected = false;
  bool get isConnected => _isConnected;
  UserIdentity? get currentIdentity => _identityManager.currentIdentity;

  /// Optional callback the UI layer wires up so presence probes only report
  /// online for accepted friends (mirrors the CLI's friend-store check).
  bool Function(String peerHex)? isAcceptedFriend;

  /// Fires whenever the accept loop verifies a signed bi-stream from [peerHex]
  /// (presence probe, message, file/moment traffic 鈥?anything). Lets the app
  /// mark the friend online reactively instead of polling for it.
  void Function(String peerHex)? onPeerSeen;

  /// Fires when a friend's presence reply carries negotiation info (a peer
  /// running 1.0.27+): version + platform. The UI stores them transiently on
  /// the Friend. Older peers announce neither.
  void Function(String peerHex, String? version, String? platform)?
      onFriendPresence;

/// Friends we have requested an update bundle from and are now awaiting the
/// inbound update-package file offer for. Keyed by peer hex 鈫?the exact
/// package file name the peer's `updateReply` promised, plus a freshness
/// deadline so a failed/stalled transfer does not keep the auto-accept gate
/// armed forever.
final Map<String, ({String fileName, DateTime until})> _awaitingUpdate = {};
static const Duration _awaitingUpdateTtl = Duration(minutes: 10);

bool isAwaitingUpdateFrom(String peerHex, {String? fileName}) {
  final entry = _awaitingUpdate[peerHex];
  if (entry == null) return false;
  if (DateTime.now().isAfter(entry.until)) {
    _awaitingUpdate.remove(peerHex);
    return false;
  }
  // Exact-name match: an unrelated `wave_*` offer (stale, mismatched or
  // send from a different flow) is NOT auto-accepted.
  if (fileName != null && fileName != entry.fileName) return false;
  return true;
}

void clearAwaitingUpdate(String peerHex) => _awaitingUpdate.remove(peerHex);

  Endpoint? _endpoint;
  EndpointAddr? _moonAddr;
  SecretKey? _secretKey;

  /// Long-lived connection to the Moon server, reused across DNS requests.
  /// Nulled on failure so the next request transparently reconnects. Opening a
  /// fresh QUIC connection per lookup is what made the desktop client appear to
  /// hammer the Moon server (one handshake for every presence probe round).
  Connection? _moonConnection;
  Future<void> _dnsChain = Future.value();

  final Map<String, EndpointAddr> _addrCache = {};

  /// Reused per-friend long-lived QUIC connections keyed by eid. All DM/voice/
  /// image/file sends and presence probes ride a single multiplexed connection
  /// per friend, so a new message no longer pays a fresh connect handshake.
  /// Entries are dropped on failure and re-established lazily. Presence and
  /// messaging are fully peer-to-peer: a friend is reached by eid through a
  /// cached address or a shared-relay fallback 鈥?the Moon server is never
  /// consulted on this path.
  final Map<String, Connection> _friendConns = {};
  final Map<String, Future<Connection>> _friendConnecting = {};
  static const Duration _peerConnectTimeout = Duration(seconds: 8);

  /// Soft online tracking: every verified incoming signed stream (or a
  /// successful probe / image / file transfer) bumps [peerHex]'s timestamp
  /// here, so "online" means "any traffic within [_activeWindow]". Peers that
  /// contact us need no probe round-trip 鈥?they are online by definition.
  final Map<String, DateTime> _lastSeen = {};
  static const Duration _activeWindow = Duration(minutes: 5);

  /// Reference count of long operations per peer (file send, moments pull,
  /// image fetch). Keeps the connection watchdog from closing a connection
  /// that is mid-transfer.
  final Map<String, int> _busyOps = {};

  /// Per-friend exponential backoff for presence probes: the more consecutive
  /// failures, the longer until the next probe, so a phone with many offline
  /// friends stops burning relay round-trips on them. The batch loop in
  /// [probeFriendsPresence] also caps how many friends are probed per round
  /// and runs with a small concurrency to keep the radio quiet.
  final Map<String, DateTime> _nextProbeAt = {};
  final Map<String, int> _probeFailCount = {};
  static const Duration _probeBaseDelay = Duration(seconds: 32);
  static const Duration _probeMaxDelay = Duration(minutes: 8);
  static const int _presenceProbeBudget = 4;

  /// Reclaims long-idle QUIC connections so a many-friend phone doesn't sit on
  /// hundreds of sockets forever. Started in [_initEndpoint], cancelled on
  /// [disconnect].
  Timer? _connWatchdog;
  static const Duration _connReclaimInterval = Duration(minutes: 2);
  static const Duration _connIdleReclaim = Duration(minutes: 5);

  /// Periodically retries flushing the outbox for friends who may have come
  /// back online without either side noticing. Each tick only touches friends
  /// that actually have queued messages, so idle connections are not hammered.
  Timer? _outboxRetryTimer;
  static const Duration _outboxRetryInterval = Duration(seconds: 30);

  /// Guards [prewarmFriend] so a chat screen doesn't hammer the peer with
  /// duplicate connection warm-ups while the user is typing.
  final Map<String, DateTime> _lastPrewarm = {};
  static const Duration _prewarmCooldown = Duration(seconds: 20);

  /// Minimum time between Moon "list online users" calls, so the app doesn't
  /// hammer the server with frequent presence polls.
  static const Duration _onlineListThrottle = Duration(seconds: 30);
  DateTime _lastOnlineList = DateTime.fromMillisecondsSinceEpoch(0);

  // 鈹€鈹€ Offline message outbox 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

  /// Messages that could not be delivered while the friend was offline. Each
  /// entry carries enough to rebuild the payload at retry time (original file
  /// paths are stored, not bytes). Persisted to disk so a restart keeps the
  /// queue. Flushed whenever the friend is detected online.
  final List<Map<String, dynamic>> _outbox = [];
  Future<void> _outboxReady = Future.value();
  final Set<String> _flushingFriends = {};

  /// UI feedback hook: called with (friendId, messageId, delivered) when a
  /// queued message is flushed. Wired in main.dart to the messagesProvider.
  void Function(String friendId, String messageId, bool delivered)? onOutboxResult;

  Future<void> _ensureOutboxLoaded() async {
    await _outboxReady;
  }

  /// Loads the persisted outbox (idempotent).
  Future<void> _loadOutbox() async {
    if (_outboxReady != Future.value()) return;
    final completer = Completer<void>();
    _outboxReady = completer.future;
    try {
      final saved = await PersistenceService.loadOutbox();
      _outbox
        ..clear()
        ..addAll(saved.where((e) => e['messageId'] != null));
    } catch (e) {
      _log('Outbox load failed: $e');
    } finally {
      completer.complete();
    }
  }

  void _persistOutbox() {
    unawaited(PersistenceService.saveOutbox(_outbox));
  }

  /// Queues [entry] for later delivery. [onOutboxResult] will fire once the
  /// message actually goes out.
  Future<void> queueMessageForRetry({
    required String friendId,
    required String messageId,
    required String type,
    String? text,
    String? path,
    String? name,
    int? durationMs,
    String? transferId,
  }) async {
    await _ensureOutboxLoaded();
    if (_outbox.any((e) => e['messageId'] == messageId)) return;
    _outbox.add({
      'messageId': messageId,
      'friendId': friendId,
      'type': type,
      'text': text,
      'path': path,
      'name': name,
      'durationMs': durationMs,
      'transferId': transferId,
      'createdAt': DateTime.now().toIso8601String(),
    });
    _persistOutbox();
    _log('Queued $type message $messageId to #$friendId for retry');
  }

  /// Names a friend was detected as online (via P2P presence probe, an incoming
  /// connection or a successful transfer), triggering an outbox flush.
  Future<void> notifyFriendOnline(String friendId) => flushFriendOutbox(friendId);

  /// Attempts to deliver every queued message for [friendId]. Returns how many
  /// went out. Entries that still fail stay queued for the next online event.
  Future<int> flushFriendOutbox(String friendId) async {
    await _ensureOutboxLoaded();
    if (_flushingFriends.contains(friendId)) return 0;
    _flushingFriends.add(friendId);
    var sentCount = 0;
    try {
      final pending = _outbox
          .where((e) => e['friendId'] == friendId)
          .toList();
      if (pending.isEmpty) return 0;

      final identity = _identityManager.currentIdentity;
      if (identity == null || _endpoint == null || _secretKey == null) return 0;

      final friend = Friend(
        id: friendId,
        name: '',
        shortId: '',
        status: FriendStatus.accepted,
        createdAt: DateTime.now(),
      );
      _log('Flushing ${pending.length} queued message(s) to ${friendId.substring(0, 16)}...');

      for (final entry in pending) {
        final messageId = entry['messageId'] as String;
        final type = entry['type'] as String;
        try {
          final ok = await _sendQueuedEntry(entry, friend, byName: identity.nickname);
          if (ok) {
            _outbox.remove(entry);
            _persistOutbox();
            sentCount++;
            unawaited(_reportOutboxResult(friendId, messageId, true));
            _log('Flushed queued $type message $messageId');
          }
        } catch (e) {
          _log('Flush of queued $type message $messageId failed: $e');
        }
      }
    } finally {
      _flushingFriends.remove(friendId);
    }
    return sentCount;
  }

  /// Periodic safety net: retries flushing the outbox. A message is only
  /// considered pending when the friend was offline at send time, so on each
  /// tick we attempt the flush again 鈥?if the friend is back, the queued
  /// frames go out; if not, they stay queued for the next tick.
  Future<void> _retryOutbox() async {
    await _ensureOutboxLoaded();
    if (_outbox.isEmpty) return;
    final friends = <String>{};
    for (final e in _outbox) {
      final friendId = e['friendId'] as String?;
      if (friendId != null && friendId.isNotEmpty) friends.add(friendId);
    }
    for (final friendId in friends) {
      if (_flushingFriends.contains(friendId)) continue;
      unawaited(flushFriendOutbox(friendId));
    }
  }

  Future<void> _reportOutboxResult(String friendId, String messageId, bool delivered) async {
    onOutboxResult?.call(friendId, messageId, delivered);
  }

  /// Delivers one queued entry with write-and-done semantics: we consider the
  /// message delivered once the signed frame is written to a live bi-stream 鈥?  /// no ack wait, so CLI peers (which never ack) don't cause duplicate retries
  /// and re-sending stops as soon as the connection is reachable.
  Future<bool> _sendQueuedEntry(Map<String, dynamic> entry, Friend friend,
      {required String byName}) async {
    final type = entry['type'] as String;
    switch (type) {
      case 'text':
        final body = MessageBody.chat(entry['text'] as String? ?? '', byName);
        await _sendBodyUnacked(friend.id, body);
        return true;
      case 'voice':
        final path = entry['path'] as String?;
        if (path == null || !File(path).existsSync()) return false;
        final mulaw = Uint8List.fromList(await File(path).readAsBytes());
        if (mulaw.isEmpty) return false;
        final body = MessageBody.voiceMessage(byName, entry['durationMs'] as int? ?? 0, mulaw);
        await _sendBodyUnacked(friend.id, body);
        return true;
      case 'image':
        final path = entry['path'] as String?;
        if (path == null || !File(path).existsSync()) return false;
        final bytes = await File(path).readAsBytes();
        if (bytes.isEmpty) return false;
        final prepared = await prepareImageForSend(bytes, entry['name'] as String? ?? 'image.jpg');
        if (prepared == null) return false;
        final body = MessageBody.imageMessage(
          byName,
          prepared.name,
          prepared.width,
          prepared.height,
          prepared.data,
          prepared.thumbPng,
        );
        await _sendBodyUnacked(friend.id, body);
        return true;
      case 'file':
        final path = entry['path'] as String?;
        if (path == null || !File(path).existsSync()) return false;
        final transferId = entry['transferId'] as String? ??
            DateTime.now().millisecondsSinceEpoch.toString();
        final result = await sendFileToFriend(
          friend,
          File(path),
          fileName: entry['name'] as String? ?? File(path).uri.pathSegments.last,
          transferId: transferId,
        );
        return result.ok;
      default:
        return false;
    }
  }

  /// Opens (or reuses) the friend's long-lived connection and writes one signed
  /// frame without waiting for an ack.
  Future<void> _sendBodyUnacked(String peerHex, MessageBody body) async {
    if (_endpoint == null || _secretKey == null) {
      throw Exception('Not initialized');
    }
    final conn = await _friendConnection(peerHex);
    final (tx, _) = await conn.openBi();
    final signedBytes = SignedMessage.sign(_secretKey!, body);
    await _writeMsg(tx, signedBytes);
    _log('Sent queued frame (${signedBytes.length} bytes) to ${peerHex.substring(0, 16)}...');
  }

  Future<bool> initialize() async {
    await _identityManager.initialize();
    unawaited(_loadOutbox());
    return _identityManager.hasIdentity;
  }

  Future<void> _initEndpoint() async {
    if (_endpoint != null && !_endpoint!.isClosed) return;

    _log('iroh version: ${Iroh.irohVersion}, ABI: ${Iroh.abiVersion}');

    final identity = _identityManager.currentIdentity;
    final sk = identity != null ? identity.secretKey : SecretKey.generate();
    _secretKey = sk;

    _log('Binding endpoint with moon-dm-v1 inbound...');
    _endpoint = await Endpoint.bind(
      secretKey: sk,
      alpns: [utf8.encode(moonDmAlpn)],
    );
    _log('Endpoint bound. ID: ${_endpoint!.id.toHex()}');

    final addr = _endpoint!.addr;
    _log('Endpoint addr - relayUrls: ${addr.relayUrls.length}, ipAddrs: ${addr.ipAddrs.length}');
    for (final ip in addr.ipAddrs) {
      _log('  ip: $ip');
    }
    for (final relay in addr.relayUrls) {
      _log('  relay: $relay');
    }

    try {
      _endpoint!.homeRelayStatus().listen((statuses) {
        for (final s in statuses) {
          _log('Relay status: $s');
        }
      });
    } catch (e) {
      _log('Relay status stream error: $e');
    }

    _startAcceptLoop();
    _connWatchdog ??= Timer.periodic(_connReclaimInterval, (_) {
      _reclaimIdleConnections();
    });
    _outboxRetryTimer ??= Timer.periodic(_outboxRetryInterval, (_) {
      _retryOutbox();
    });
  }

  void _startAcceptLoop() {
    _log('Starting accept loop...');
    () async {
      while (_endpoint != null && !_endpoint!.isClosed) {
        try {
          final conn = await _endpoint!.accept();
          if (conn == null) {
            _log('Accept returned null 鈥?endpoint closed');
            break;
          }
          final peerId = conn.remoteId;
          final peerHex = peerId.toHex();
          _log('Incoming connection accepted from ${peerHex.substring(0, 16)}...');
          _handleIncomingConnection(conn);
        } catch (e) {
          _log('Accept loop error: $e');
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    }();
  }

  Future<void> _handleIncomingConnection(Connection conn) async {
    try {
      final peerId = conn.remoteId;
      final peerHex = peerId.toHex();
      _log('Incoming conn established from ${peerHex.substring(0, 16)}...');

      while (true) {
        try {
          final (tx, rx) = await conn.acceptBi();

          // A peer may open a bi-stream and delay its first frame (slow peer,
          // congested relay). Timing out the FIRST read would break the whole
          // accept loop and starve every other stream (presence probes and the
          // parallel file-chunk streams alike), so only give up on a silent
          // stream and keep accepting the rest.
          Uint8List? msgBytes;
          try {
            msgBytes = await _readMsg(rx).timeout(const Duration(seconds: 90));
          } on TimeoutException {
            _log('Incoming stream: silent bi dropped after 90s');
            unawaited(_drainToEof(rx));
            continue;
          }
          if (msgBytes == null) break;

          final (fromPk, body) = SignedMessage.verify(msgBytes);
          final fromHex = fromPk.toHex();
          markSeen(fromHex);
          onPeerSeen?.call(fromHex);
          _log('Incoming signed message from ${fromHex.substring(0, 16)}...: ${body.kind}');

          // DM-type traffic is for accepted friends only: messages (chat/voice/
          // image), files, moments pushed to us and calls. Requests we initiated
          // (presence probes, update fetches, moment pulls) keep their own
          // server-side gates in the respective handlers. A stranger's frame is
          // drained (never acked) so the sender times out; no chat entry, no
          // unread badge, no disk write from an unaccepted peer.
          final accepted = _isAcceptedPeer(fromHex);
          final needsFriend = body.kind == MessageBodyKind.chat ||
              body.kind == MessageBodyKind.voiceMessage ||
              body.kind == MessageBodyKind.imageMessage ||
              body.kind == MessageBodyKind.fileOffer ||
              body.kind == MessageBodyKind.fileChunk ||
              body.kind == MessageBodyKind.callInvite ||
              body.kind == MessageBodyKind.momentFeed ||
              body.kind == MessageBodyKind.momentImageData ||
              body.kind == MessageBodyKind.momentReact ||
              body.kind == MessageBodyKind.momentDelete;
          if (needsFriend && !accepted) {
            _log('Ignoring ${body.kind} from non-friend ${fromHex.substring(0, 16)}...');
            unawaited(_drainToEof(rx));
            continue;
          }

          if (body.kind == MessageBodyKind.fileOffer) {
            unawaited(_openFileSession(fromHex, body, tx, rx));
            continue;
          }

          if (body.kind == MessageBodyKind.fileChunk) {
            final session = _fileSessions[body.fileId ?? ''];
            if (session != null) {
              unawaited(_drainChunkStream(session, rx, first: body));
            } else {
              unawaited(_drainToEof(rx));
            }
            continue;
          }

          if (body.kind == MessageBodyKind.presenceProbe) {
            await _handlePresenceProbe(fromHex, tx);
            continue;
          }

          if (body.kind == MessageBodyKind.updateRequest) {
            unawaited(_handleUpdateRequest(fromHex, body, tx));
            continue;
          }

          if (body.kind == MessageBodyKind.callInvite) {
            unawaited(_handleIncomingCallInvite(fromHex, body, tx, rx));
            continue;
          }

          if (body.kind == MessageBodyKind.voiceMessage) {
            await _handleVoiceMessage(fromHex, body, tx);
            continue;
          }

          if (body.kind == MessageBodyKind.imageMessage) {
            await _handleImageMessage(fromHex, body, tx);
            continue;
          }

          if (body.kind == MessageBodyKind.momentFetch) {
            await _handleMomentFetch(fromHex, body, tx);
            continue;
          }

          if (body.kind == MessageBodyKind.momentImage) {
            await _handleMomentImageRequest(fromHex, body, tx);
            continue;
          }

          if (body.kind == MessageBodyKind.momentFeed) {
            await _handleMomentFeed(fromHex, body, tx);
            continue;
          }

          if (body.kind == MessageBodyKind.momentImageData) {
            await _handleMomentImageData(fromHex, body, tx);
            continue;
          }

          if (body.kind == MessageBodyKind.momentReact) {
            await _handleMomentReact(fromHex, body, tx);
            continue;
          }

          if (body.kind == MessageBodyKind.momentDelete) {
            await _handleMomentDelete(fromHex, body, tx);
            continue;
          }

          _handleIncomingBody(fromPk, fromHex, body, tx);
        } catch (e) {
          _log('Incoming stream error: $e');
          break;
        }
      }
    } catch (e) {
      _log('Incoming conn failed: $e');
    }
  }

  /// Replies to a presence probe. We advertise ourselves as online only to
  /// accepted friends; everyone else gets `online: false` (mirrors the CLI's
  /// `handle_presence_probe`).
  Future<void> _handlePresenceProbe(String fromHex, SendStream tx) async {
    try {
      final friend = isAcceptedFriend != null && isAcceptedFriend!(fromHex);
      // Version/platform are only advertised to accepted friends; strangers get
      // the same minimal "offline" reply as before (no metadata leak).
      final reply = SignedMessage.sign(_secretKey!, MessageBody.presenceReply(
        friend,
        version: friend ? appVersion : null,
        platform: friend ? myPlatform : null,
      ));
      await _writeMsg(tx, reply);
      _log('Presence probe from ${fromHex.substring(0, 16)}... replied online=$friend');
    } catch (e) {
      _log('Presence probe reply failed: $e');
    }
  }

  /// Serves a friend's `updateRequest` 鈥?strictly for my own platform build
  /// (鍚勭増鏈彧璐熻矗鏈増鐗堟湰鏇存柊锛屼笉璐熻矗鍏朵粬骞冲彴). A requester running another
  /// platform is refused up front; a matching-platform requester gets the
  /// latest local `wave_*` package newer than their version, replied via
  /// [MessageBody.updateReply], then streamed with the ordinary file offer flow
  /// (the receiver auto-accepts it). Only accepted friends are served.
  Future<void> _handleUpdateRequest(
      String fromHex, MessageBody body, SendStream tx) async {
    try {
      final accepted = isAcceptedFriend != null && isAcceptedFriend!(fromHex);
      if (!accepted) {
        await _writeMsg(tx, SignedMessage.sign(_secretKey!,
            MessageBody.updateReply(ok: false, reason: '浠呴檺濂藉弸鑾峰彇鏇存柊')));
        return;
      }
      final my = myPlatform;
      final req = body.updatePlatform;
      if (req != null && req != my) {
        await _writeMsg(tx, SignedMessage.sign(_secretKey!, MessageBody.updateReply(
            ok: false,
            reason: '鏈涓?$my 鐗堬紝浠呮彁渚?$my 骞冲彴鏇存柊鍖咃紝涓嶆彁渚?$req 鏇存柊')));
        return;
      }
      final pkg = await UpdateService.findLocalUpdatePackage(
        platform: my,
        newerThan: body.updateCurrentVersion ?? '0',
      );
      if (pkg == null) {
        await _writeMsg(tx, SignedMessage.sign(_secretKey!, MessageBody.updateReply(
            ok: false, reason: '鏈鏆傛棤 $my 骞冲彴鐨勬洿鏂板寘')));
        return;
      }
      await _writeMsg(tx, SignedMessage.sign(_secretKey!,
          MessageBody.updateReply(ok: true,
              version: pkg.version, fileName: pkg.fileName, size: pkg.size)));
      final friend = Friend(
        id: fromHex,
        name: fromHex.substring(0, 12),
        shortId: '',
        status: FriendStatus.accepted,
        createdAt: DateTime.now(),
      );
      await sendFileToFriend(friend, File(pkg.path), fileName: pkg.fileName);
    } catch (e) {
      _log('Update request handler failed: $e');
    }
  }

  void _handleIncomingBody(
    PublicKey fromPk,
    String fromHex,
    MessageBody body,
    SendStream tx,
  ) {
    switch (body.kind) {
      case MessageBodyKind.chat:
        final msg = Message(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          senderId: fromHex,
          receiverId: _endpoint!.id.toHex(),
          content: body.text ?? '',
          timestamp: DateTime.now(),
          type: MessageType.text,
          isMe: false,
          status: MessageStatus.delivered,
          senderName: body.fromName,
        );
        _messageController.add(msg);
        _log('DM received from ${body.fromName}: ${body.text}');
        _sendAck(tx);
        break;

      case MessageBodyKind.friendRequest:
        final friend = Friend(
          id: fromHex,
          name: body.name ?? 'Unknown',
          shortId: body.shortId ?? '',
          status: FriendStatus.pendingIn,
          createdAt: DateTime.now(),
        );
        _friendRequestController.add(friend);
        _log('Friend request from ${body.name} (#${body.shortId})');
        _sendAck(tx);
        break;

      case MessageBodyKind.friendAccept:
        _log('Friend accepted from ${fromHex.substring(0, 16)}...');
        _incomingMessageController.add('friend_accepted:$fromHex');
        _sendAck(tx);
        break;

      case MessageBodyKind.friendReject:
        _log('Friend rejected from ${fromHex.substring(0, 16)}...');
        _incomingMessageController.add('friend_rejected:$fromHex');
        _sendAck(tx);
        break;

      case MessageBodyKind.friendRemove:
        _log('Friend removed by ${fromHex.substring(0, 16)}...');
        _incomingMessageController.add('friend_removed:$fromHex');
        _sendAck(tx);
        break;

      case MessageBodyKind.nickChanged:
        _log('NickChanged from ${fromHex.substring(0, 16)}...: ${body.newName}');
        _incomingMessageController.add('nick_changed:$fromHex:${body.newName}');
        _sendAck(tx);
        break;

      default:
        _log('Unknown message body kind: ${body.kind}');
        _sendAck(tx);
    }
  }

  /// True when [peerHex] is one of our accepted friends. Default-open when no
  /// membership callback is wired (the UI wires it in main.dart) so helpers
  /// don't dead-lock offline/test paths, but in the running app strangers are
  /// rejected before any message/file/drive work.
  bool _isAcceptedPeer(String peerHex) =>
      isAcceptedFriend == null || isAcceptedFriend!(peerHex);

  Future<void> _sendAck(SendStream tx) async {
    try {
      final ack = Uint8List.fromList([111, 107]); // "ok"
      final lenBuf = Uint8List(4);
      lenBuf.buffer.asByteData().setUint32(0, ack.length, Endian.little);
      await tx.writeAll(lenBuf);
      await tx.writeAll(ack);
      await tx.finish();
    } catch (_) {}
  }

  /// Receives a complete VoiceMessage, persists the 渭-law buffer to a file and
  /// surfaces it on the message stream. Mirrors the CLI's `save_voice_message`.
  Future<void> _handleVoiceMessage(String fromHex, MessageBody body, SendStream tx) async {
    final data = body.voiceData;
    String? savedPath;
    if (data != null && data.isNotEmpty) {
      if (data.length <= voiceMaxBytes) {
        try {
          final dir = await _fileSaveDir();
          final path = await _uniquePath(dir, 'voice_${DateTime.now().millisecondsSinceEpoch}.mulaw');
          await File(path).writeAsBytes(data);
          savedPath = path;
        } catch (e) {
          _log('Voice save failed: $e');
        }
      } else {
        _log('Dropping oversized voice from ${fromHex.substring(0, 16)}...: ${data.length} bytes');
      }
    }
    final durationMs = body.voiceDuration ?? 0;
    final msg = Message(
      id: 'v_${fromHex.substring(0, 12)}_${DateTime.now().millisecondsSinceEpoch}',
      senderId: fromHex,
      receiverId: _endpoint!.id.toHex(),
      content: '[Voice] ${(durationMs / 1000).toStringAsFixed(1)}s',
      timestamp: DateTime.now(),
      type: MessageType.voice,
      isMe: false,
      status: MessageStatus.delivered,
      senderName: body.voiceName,
      fileName: 'voice.mulaw',
      filePath: savedPath,
      fileSize: data?.length,
    );
    _messageController.add(msg);
    _log('Voice message received from ${body.voiceName} (${data?.length ?? 0} bytes, ${durationMs}ms)');
    _sendAck(tx);
  }

  /// Receives a complete ImageMessage, persists the full image to disk and
  /// surfaces it on the message stream. Mirrors the CLI's `save_image_message`
  /// (extension whitelisted to ASCII alphanumeric, 鈮? chars, defers to `img`).
  Future<void> _handleImageMessage(String fromHex, MessageBody body, SendStream tx) async {
    final data = body.imageData;
    String? savedPath;
    if (data != null && data.isNotEmpty) {
      if (data.length <= imageMaxBytes) {
        try {
          final dir = await _imageSaveDir();
          final path = await _uniquePath(
              dir, 'img_${DateTime.now().millisecondsSinceEpoch}.${_imageExt(body.imageName)}');
          await File(path).writeAsBytes(data);
          savedPath = path;
        } catch (e) {
          _log('Image save failed: $e');
        }
      } else {
        _log('Dropping oversized image from ${fromHex.substring(0, 16)}...: ${data.length} bytes');
      }
    }
    final msg = Message(
      id: 'img_${fromHex.substring(0, 12)}_${DateTime.now().millisecondsSinceEpoch}',
      senderId: fromHex,
      receiverId: _endpoint!.id.toHex(),
      content: '[Image] ${body.imageName ?? ''}',
      timestamp: DateTime.now(),
      type: MessageType.image,
      isMe: false,
      status: MessageStatus.delivered,
      senderName: body.fromName,
      fileName: body.imageName,
      filePath: savedPath,
      fileSize: data?.length,
    );
    _messageController.add(msg);
    _log('Image message received from ${body.fromName} (${data?.length ?? 0} bytes)');
    _sendAck(tx);
  }

  Future<EndpointAddr?> _loadMoonAddr() async {
    _log('Loading Moon server address...');
    try {
      final serverPkBytes = _hexToBytes(moonServerId);
      final id = PublicKey.fromBytes(serverPkBytes);
      final moonAddr = EndpointAddr(id, ipAddrs: moonServerIpAddrs);
      _log('Moon EndpointAddr created');
      return moonAddr;
    } catch (e) {
      _log('Failed to create Moon address: $e');
      return null;
    }
  }

  Future<bool> connectAndRegister() async {
    final identity = _identityManager.currentIdentity;
    if (identity == null) {
      _statusController.add('No identity found');
      return false;
    }

    _statusController.add('Initializing iroh endpoint...');
    try {
      await _initEndpoint();
    } catch (e) {
      _statusController.add('Failed to init iroh: $e');
      return false;
    }

    _statusController.add('Loading Moon server address...');
    _moonAddr = await _loadMoonAddr();
    if (_moonAddr == null) {
      _statusController.add('No Moon server address found');
      return false;
    }

    _statusController.add('Registering with Moon server...');
    try {
      final shortId = await _registerWithMoon();
      if (shortId != null) {
        _isConnected = true;
        _connectionController.add(true);
        _statusController.add('Registered! Short ID: #$shortId');
        _log('SUCCESS: Registered! Short ID: #$shortId');
        return true;
      } else {
        _statusController.add('Registration failed');
        return false;
      }
    } catch (e, st) {
      _statusController.add('Registration error: $e');
      _log('ERROR: $e\n$st');
      _isConnected = false;
      _connectionController.add(false);
      return false;
    }
  }

  Future<String?> _registerWithMoon() async {
    final identity = _identityManager.currentIdentity;
    if (identity == null || _endpoint == null || _moonAddr == null) return null;

    final myAddr = _endpoint!.addr;
    final idBytes = Uint8List.fromList(_hexToBytes(identity.publicKeyHex));
    final req = MoonDnsRequest.register(idBytes, identity.nickname, myAddr);
    final reqBytes = req.encode();

    final resp = await _sendDnsRequestToMoon(reqBytes);
    if (resp == null) return null;

    final decoded = MoonDnsResponse.decode(resp);
    if (decoded.kind == MoonDnsResponseKind.registered) {
      final shortId = decoded.shortId ?? '';
      await _identityManager.updateShortId(shortId);
      return shortId;
    } else if (decoded.kind == MoonDnsResponseKind.error) {
      _log('Moon error: ${decoded.msg}');
      return null;
    }
    return null;
  }

  Future<Uint8List?> _sendDnsRequestToMoon(Uint8List reqBytes) {
    if (_endpoint == null || _moonAddr == null) return Future.value(null);
    final done = Completer<Uint8List?>();
    _dnsChain = _dnsChain.then((_) async {
      final resp = await _dnsRequestOnConnection(reqBytes);
      done.complete(resp);
    }).catchError((Object e) {
      _log('DNS request chain error: $e');
      done.complete(null);
    });
    return done.future;
  }

  /// Runs a single Moon DNS round-trip over the shared [_moonConnection],
  /// opening a fresh bi-stream per request. Reconnects the connection only when
  /// it is dead, so lookups no longer each pay a new QUIC handshake.
  Future<Uint8List?> _dnsRequestOnConnection(Uint8List reqBytes) async {
    try {
      var conn = _moonConnection;
      if (conn == null) {
        _log('DNS: connecting to Moon...');
        conn = await _endpoint!
            .connect(_moonAddr!, utf8.encode(moonRouterAlpn))
            .timeout(const Duration(seconds: 6));
        _moonConnection = conn;
        _log('DNS: connected (persistent, reused for future lookups)');
      }

      final (tx, rx) = await conn.openBi().timeout(const Duration(seconds: 6));
      final lenBuf = Uint8List(4);
      lenBuf.buffer.asByteData().setUint32(0, reqBytes.length, Endian.little);
      await tx.writeAll(lenBuf);
      await tx.writeAll(reqBytes);
      await tx.finish();

      final respLenBuf = await rx.readExact(4).timeout(const Duration(seconds: 6));
      final respLen = respLenBuf.buffer.asByteData().getUint32(0, Endian.little);
      final respBuf = await rx.readExact(respLen).timeout(const Duration(seconds: 6));
      return respBuf;
    } catch (e) {
      _log('DNS request to Moon failed (reconnecting next time): $e');
      _moonConnection = null;
      return null;
    }
  }

  Future<MoonDnsRegistryEntry?> lookupUser(String shortId) async {
    if (_endpoint == null || _moonAddr == null) return null;
    _log('LOOKUP_ENTER #$shortId');
    Uint8List? resp;
    try {
      final req = MoonDnsRequest.lookup(shortId);
      final reqBytes = req.encode();
      resp = await _sendDnsRequestToMoon(reqBytes);
      _log('LOOKUP: _send returned ${resp == null ? "null" : "${resp.length} bytes"}');
      if (resp == null) return null;

      MoonDnsResponse decoded;
      try {
        decoded = MoonDnsResponse.decode(resp);
      } catch (e) {
        final hexResp = resp.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
        _log('Lookup DECODE_ERROR: $e raw=$hexResp');
        _lookupResultController.add(null);
        return null;
      }
        if (decoded.kind == MoonDnsResponseKind.lookupResult) {
        final entry = decoded.entry;
        if (entry != null && entry.addr != null) {
          _cacheAddr(entry.id.fold('', (h, b) => '$h${b.toRadixString(16).padLeft(2, '0')}'), entry.addr!);
          _log('Lookup #$shortId: ${entry.name} (${entry.id.length} bytes) addr=${entry.addr}');
        } else {
          _log('Lookup #$shortId: ${entry != null ? "found but addr is null (${entry.name}, ${entry.id.length} bytes)" : "not found"}');
        }
        _lookupResultController.add(entry != null ? {
          'id': entry.id.fold('', (h, b) => '$h${b.toRadixString(16).padLeft(2, '0')}'),
          'name': entry.name,
          'short_id': entry.shortId,
        } : null);
        return entry;
      } else if (decoded.kind == MoonDnsResponseKind.error) {
        _log('Lookup error: ${decoded.msg}');
        _lookupResultController.add(null);
        return null;
      }
      _lookupResultController.add(null);
      return null;
    } catch (e) {
      _log('Lookup error: $e');
      _lookupResultController.add(null);
      return null;
    }
  }

  Future<void> listOnlineUsers() async {
    if (_endpoint == null || _moonAddr == null) return;
    final now = DateTime.now();
    if (now.difference(_lastOnlineList) < _onlineListThrottle) return;
    _lastOnlineList = now;
    try {
      final req = MoonDnsRequest.list();
      final reqBytes = req.encode();
      final resp = await _sendDnsRequestToMoon(reqBytes);
      if (resp == null) {
        _onlineUsersController.add([]);
        return;
      }

final decoded = MoonDnsResponse.decode(resp);
      if (decoded.kind == MoonDnsResponseKind.listResult && decoded.entries != null) {
        final users = <Map<String, dynamic>>[];
        for (final e in decoded.entries!) {
          if (e.addr != null) {
            final hex = e.id.fold('', (h, b) => '$h${b.toRadixString(16).padLeft(2, '0')}');
            _cacheAddr(hex, e.addr!);
          }
          users.add({
            'id': e.id.fold('', (h, b) => '$h${b.toRadixString(16).padLeft(2, '0')}'),
            'name': e.name,
            'short_id': e.shortId,
          });
        }
        _onlineUsersController.add(users);
      } else {
        _onlineUsersController.add([]);
      }
    } catch (e) {
      _log('List error: $e');
      _onlineUsersController.add([]);
    }
  }

  Future<void> _sendToPeer(String peerHex, MessageBody body) async {
    if (_endpoint == null) throw Exception('Not initialized');

    final conn = await _friendConnection(peerHex);
    _log('P2P connected to ${peerHex.substring(0, 16)}...');

    final (tx, rx) = await conn.openBi();
    final signedBytes = SignedMessage.sign(_secretKey!, body);
    await _writeMsg(tx, signedBytes);
    _log('P2P message sent (${signedBytes.length} bytes)');

    try {
      await _readMsg(rx).timeout(_ackTimeout);
    } on TimeoutException {
      _log('No ack within ${_ackTimeout.inSeconds}s from ${peerHex.substring(0, 16)}...');
    } catch (e) {
      _dropFriendConnection(peerHex);
    }
  }

  /// Builds a relay-only [EndpointAddr] for [peerHex] using the shared default relays,
  /// so the peer can be reached by eid without a prior Moon lookup.
  EndpointAddr _relayAddrForPeer(String peerHex) {
    final id = PublicKey.fromBytes(_hexToBytes(peerHex));
    return EndpointAddr(
      id,
      relayUrls: defaultRelayUrls.map(RelayUrl.parse).toList(),
    );
  }

  /// Sends a friend request directly to a peer known only by its eid (public key hex),
  /// using the shared default relays 鈥?works even when the Moon server is unreachable.
  Future<bool> sendFriendRequestById(String peerIdHex, {String? friendName, String? shortId}) async {
    final identity = _identityManager.currentIdentity;
    if (identity == null || _endpoint == null) return false;

    final hex = peerIdHex.trim();
    if (!_isValidHexKey(hex)) {
      _statusController.add('Invalid endpoint ID / public key');
      return false;
    }

    final peerHex = hex.toLowerCase();
    try {
      final addr = _relayAddrForPeer(peerHex);
      _cacheAddr(peerHex, addr);
      _log('Friend request by eid: peer=${peerHex.substring(0, 16)}..., addr=$addr');

      final body = MessageBody.friendRequest(friendName ?? identity.nickname, shortId ?? identity.shortId ?? '');
      await _sendToPeer(peerHex, body);
      _statusController.add('Friend request sent to ${peerHex.substring(0, 16)}...');
      return true;
    } catch (e) {
      _log('Friend request by eid failed: $e');
      _statusController.add('Friend request failed: $e');
      return false;
    }
  }

  bool _isValidHexKey(String hex) {
    if (hex.length != 64) return false;
    return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex);
  }

  Future<void> sendMessage(String targetShortId, String text) async {
    final identity = _identityManager.currentIdentity;
    if (identity == null || !_isConnected) return;

    final entry = await lookupUser(targetShortId);
    if (entry == null || entry.addr == null) {
      _statusController.add('User #$targetShortId not found');
      return;
    }

    final body = MessageBody.chat(text, identity.nickname);
    try {
      await _sendToPeer(entry.id.fold('', (h, b) => '$h${b.toRadixString(16).padLeft(2, '0')}'), body);
    } catch (e) {
      _log('Send message failed: $e');
      _statusController.add('Send failed: $e');
    }
  }

  /// Returns a live, long-lived connection to the peer [peerHex] (by eid). A new
  /// connection is opened from the cached address when known, otherwise a
  /// relay-only address built from the shared default relays 鈥?the Moon server
  /// is never consulted on this path. Concurrent callers share the same
  /// in-flight connect instead of racing.
  Future<Connection> _friendConnection(String peerHex) async {
    final existing = _friendConns[peerHex];
    if (existing != null) return existing;
    final inFlight = _friendConnecting[peerHex];
    if (inFlight != null) return inFlight;
    final fut = _connectFriendPeer(peerHex);
    _friendConnecting[peerHex] = fut;
    try {
      final conn = await fut;
      _friendConns[peerHex] = conn;
      return conn;
    } finally {
      _friendConnecting.remove(peerHex);
    }
  }

  Future<Connection> _connectFriendPeer(String peerHex) async {
    var addr = _addrCache[peerHex];
    if (addr == null) {
      addr = _relayAddrForPeer(peerHex);
      _cacheAddr(peerHex, addr);
    }
    return _endpoint!
        .connect(addr, utf8.encode(moonDmAlpn))
        .timeout(_peerConnectTimeout);
  }

  /// Drops the connection for [peerHex] after a failed send/probe/stream so the
  /// next operation transparently reconnects instead of reusing a dead socket.
  void _dropFriendConnection(String peerHex) {
    _friendConnecting.remove(peerHex);
    final conn = _friendConns.remove(peerHex);
    if (conn != null) {
      try {
        conn.close();
      } catch (_) {}
    }
  }

  /// Opens (and keeps) a connection to [friend] so hole-punching / relay
  /// handshake happens while the user is still typing instead of when they hit
  /// send. Later DM/image/file sends reuse this connection. Never throws.
  Future<void> prewarmFriend(Friend friend) async {
    if (_endpoint == null || friend.id.isEmpty) return;
    final last = _lastPrewarm[friend.id];
    if (last != null &&
        DateTime.now().difference(last) < _prewarmCooldown) {
      return;
    }
    _lastPrewarm[friend.id] = DateTime.now();
    try {
      await _friendConnection(friend.id).timeout(const Duration(seconds: 6));
      _log('Prewarmed connection to ${friend.name}');
    } catch (e) {
      _dropFriendConnection(friend.id);
      _log('Prewarm to ${friend.name} failed: $e');
    }
  }

  /// Sends a text message to a friend and waits for the peer's ACK.
  /// Returns `true` when the peer acknowledged (delivered), `false` otherwise.
  Future<bool> sendMessageToFriend(Friend friend, String text) async {
    final identity = _identityManager.currentIdentity;
    if (identity == null || _endpoint == null) return false;

    if (friend.id.isEmpty) {
      _statusController.add('Friend has no ID');
      return false;
    }

    final body = MessageBody.chat(text, identity.nickname);
    try {
      final conn = await _friendConnection(friend.id);
      final (tx, rx) = await conn.openBi();
      final signedBytes = SignedMessage.sign(_secretKey!, body);
      await _writeMsg(tx, signedBytes);
      _log('DM sent to ${friend.name} (${signedBytes.length} bytes)');
      try {
        final ack = await _readMsg(rx).timeout(_ackTimeout);
        if (ack == null) {
          _log('DM to ${friend.name} no ack (offline?)');
          return false;
        }
        _log('DM acked by ${friend.name}');
        return true;
      } on TimeoutException {
        _log('DM to ${friend.name} no ack within ${_ackTimeout.inSeconds}s');
        return false;
      } catch (e) {
        _dropFriendConnection(friend.id);
        _log('DM ack read failed for ${friend.name}: $e');
        return false;
      }
    } catch (e) {
      _dropFriendConnection(friend.id);
      _log('Send message failed: $e');
      _statusController.add('Send failed: $e');
      return false;
    }
  }

  /// Maximum accepted voice-message payload size (mirrors the CLI's
  /// `check_voice_size`: `MAX_MSG_LEN - 1024`).
  static const int voiceMaxBytes = 1047552;

  /// Sends a recorded voice message (already 渭-law encoded) to a friend.
  /// Returns true when the peer acknowledged receipt. Mirrors the CLI's
  /// `send_voice`.
  Future<bool> sendVoiceMessage(Friend friend, Uint8List mulaw, int durationMs) async {
    final identity = _identityManager.currentIdentity;
    if (identity == null || _endpoint == null) return false;
    if (friend.id.isEmpty) return false;
    if (mulaw.length > voiceMaxBytes) {
      _statusController.add('Voice message too long');
      return false;
    }

    final body = MessageBody.voiceMessage(identity.nickname, durationMs, mulaw);
    try {
      final conn = await _friendConnection(friend.id);
      final (tx, rx) = await conn.openBi();
      final signedBytes = SignedMessage.sign(_secretKey!, body);
      await _writeMsg(tx, signedBytes);
      _log('Voice sent to ${friend.name} (${mulaw.length} bytes, ${durationMs}ms)');
      try {
        final ack = await _readMsg(rx).timeout(_ackTimeout);
        if (ack == null) {
          _log('Voice to ${friend.name} no ack (offline?)');
          return false;
        }
        _log('Voice acked by ${friend.name}');
        return true;
      } on TimeoutException {
        _log('Voice to ${friend.name} no ack within ${_ackTimeout.inSeconds}s');
        return false;
      } catch (e) {
        _dropFriendConnection(friend.id);
        _log('Voice ack read failed for ${friend.name}: $e');
        return false;
      }
    } catch (e) {
      _dropFriendConnection(friend.id);
      _log('Send voice failed: $e');
      _statusController.add('Send failed: $e');
      return false;
    }
  }

  /// Maximum accepted image payload size, mirrors the CLI's `MAX_IMAGE_BYTES`.
  static const int imageMaxBytes = 8 * 1024 * 1024;

  /// Sends a full ImageMessage (original image + PNG thumbnail) to a friend.
  /// Returns true when the peer acknowledged receipt. Mirrors the CLI's
  /// `send_image`.
  Future<bool> sendImageMessage(Friend friend, Uint8List data, String name,
      int width, int height, Uint8List thumb) async {
    final identity = _identityManager.currentIdentity;
    if (identity == null || _endpoint == null) return false;
    if (friend.id.isEmpty) return false;
    if (data.length > imageMaxBytes) {
      _statusController.add('Image too large (max 8 MB)');
      return false;
    }

    final body =
        MessageBody.imageMessage(identity.nickname, name, width, height, data, thumb);
    try {
      final conn = await _friendConnection(friend.id);
      final (tx, rx) = await conn.openBi();
      final signedBytes = SignedMessage.sign(_secretKey!, body);
      await _writeMsg(tx, signedBytes);
      _log('Image sent to ${friend.name} (${data.length} bytes, ${width}x$height)');
      try {
        final ack = await _readMsg(rx).timeout(_ackTimeout);
        if (ack == null) {
          _log('Image to ${friend.name} no ack (offline?)');
          return false;
        }
        _log('Image acked by ${friend.name}');
        return true;
      } on TimeoutException {
        _log('Image to ${friend.name} no ack within ${_ackTimeout.inSeconds}s');
        return false;
      } catch (e) {
        _dropFriendConnection(friend.id);
        _log('Image ack read failed for ${friend.name}: $e');
        return false;
      }
    } catch (e) {
      _dropFriendConnection(friend.id);
      _log('Send image failed: $e');
      _statusController.add('Send failed: $e');
      return false;
    }
  }

  static const Duration _probeTimeout = Duration(seconds: 10);
  static const Duration _ackTimeout = Duration(seconds: 8);

  /// Probes a single friend over P2P and returns whether they replied "online".
  /// Mirrors the CLI's `presence::probe_one`: opens a bi-stream, sends a
  /// `PresenceProbe` and expects a `PresenceReply { online: true || false }`
  /// back. A timeout/connection failure means the peer is offline. Probing
  /// rides the same reused long-lived connection as messaging.
  /// Records that [peerHex] produced or consumed traffic just now. The
  /// soft-online window ([_activeWindow]) and the connection watchdog both key
  /// off this timestamp.
  void markSeen(String peerHex) {
    if (peerHex.isEmpty) return;
    _lastSeen[peerHex] = DateTime.now();
  }

  bool isActive(String peerHex, {Duration? within}) {
    if (peerHex.isEmpty) return false;
    final t = _lastSeen[peerHex];
    return t != null && t.isAfter(DateTime.now().subtract(within ?? _activeWindow));
  }

  void _beginOp(String peerHex) {
    if (peerHex.isEmpty) return;
    _busyOps[peerHex] = (_busyOps[peerHex] ?? 0) + 1;
  }

  void _endOp(String peerHex) {
    if (peerHex.isEmpty) return;
    final c = _busyOps[peerHex];
    if (c == null) return;
    if (c <= 1) {
      _busyOps.remove(peerHex);
    } else {
      _busyOps[peerHex] = c - 1;
    }
  }

  bool _isBusy(String peerHex) => (_busyOps[peerHex] ?? 0) > 0;

  /// Bounds how many on-demand moment-image bi-streams are open at once, so
  /// scrolling a feed with many posts doesn't fire hundreds of parallel
  /// requests. FIFO waiters are released as slots free up.
  static const int _momentImageMaxConcurrent = 4;
  int _momentImageInflight = 0;
  final List<Completer<void>> _momentImageWaiters = [];

  Future<T> _withMomentImageSlot<T>(Future<T> Function() task) async {
    if (_momentImageInflight >= _momentImageMaxConcurrent) {
      final c = Completer<void>();
      _momentImageWaiters.add(c);
      await c.future;
    }
    _momentImageInflight++;
    try {
      return await task();
    } finally {
      _momentImageInflight--;
      if (_momentImageWaiters.isNotEmpty) {
        _momentImageWaiters.removeAt(0).complete();
      }
    }
  }

  Future<bool> probeFriendPresence(Friend friend) async {
    if (_endpoint == null || _secretKey == null) return false;
    if (friend.id.isEmpty) return false;

    try {
      final conn = await _friendConnection(friend.id);
      final (tx, rx) = await conn.openBi().timeout(_probeTimeout);
      final signedBytes =
          SignedMessage.sign(_secretKey!, MessageBody.presenceProbe());
      await _writeMsg(tx, signedBytes);

      final reply = await _readMsg(rx).timeout(_probeTimeout);
      if (reply == null) {
        _log('Presence probe ${friend.name}: no reply (offline)');
        _bumpProbeBackoff(friend.id);
        return false;
      }
      final (_, body) = SignedMessage.verify(reply);
      if (body.kind == MessageBodyKind.presenceReply) {
        final v = body.version;
        if (v != null && v.trim().isNotEmpty) {
          onFriendPresence?.call(friend.id, v.trim(), body.presencePlatform);
          _log('Presence probe ${friend.name}: version v$v platform=${body.presencePlatform}');
        }
      }
      final online =
          body.kind == MessageBodyKind.presenceReply && body.online == true;
      if (online) {
        markSeen(friend.id);
        _probeFailCount.remove(friend.id);
      } else {
        _bumpProbeBackoff(friend.id);
      }
      _log('Presence probe ${friend.name}: ${online ? "online" : "offline"}');
      return online;
    } catch (e) {
      _bumpProbeBackoff(friend.id);
      _dropFriendConnection(friend.id);
      _log('Presence probe ${friend.name} failed (offline): $e');
      return false;
    }
  }

  /// Exponential backoff: 32 s 鈫?64 s 鈫?128 s 鈫?鈥?capped at [_probeMaxDelay].
  void _bumpProbeBackoff(String peerHex) {
    final c = (_probeFailCount[peerHex] ?? 0) + 1;
    _probeFailCount[peerHex] = c;
    var delay = _probeBaseDelay.inSeconds << (c - 1); // 32,64,128,256鈥?    if (delay > _probeMaxDelay.inSeconds) delay = _probeMaxDelay.inSeconds;
    _nextProbeAt[peerHex] = DateTime.now().add(Duration(seconds: delay));
  }

  /// Probes every accepted friend over P2P and returns a map of friend-id 鈫?  /// online **only for friends whose status was determined this round**.
  /// Friends with traffic inside [_activeWindow] are online by definition
  /// (no probe needed). Friends whose backoff hasn't expired are skipped so
  /// the caller keeps their last-known state instead of flipping them
  /// prematurely to "offline". To protect the radio, at most
  /// [_presenceProbeBudget] friends are actually probed per round with a
  /// concurrency ceiling of 2; the rest are caught on the next round.
  Future<Map<String, bool>> probeFriendsPresence(List<Friend> friends) async {
    final result = <String, bool>{};
    final accepted =
        friends.where((f) => f.status == FriendStatus.accepted).toList();
    final now = DateTime.now();
    final toProbe = <Friend>[];
    for (final f in accepted) {
      if (isActive(f.id)) {
        result[f.id] = true;
        continue;
      }
      final next = _nextProbeAt[f.id];
      if (next != null && now.isBefore(next)) continue; // in backoff
      if (toProbe.length >= _presenceProbeBudget) continue; // caught next round
      toProbe.add(f);
    }
    // Concurrency-2 fan-out keeps probe latency low while staying gentle
    // on the radio (versus sequential which can block the tick for >30 s
    // on a full budget).
    const concurrency = 2;
    for (var i = 0; i < toProbe.length; i += concurrency) {
      final slice = toProbe.skip(i).take(concurrency).toList();
      final outcomes = await Future.wait(
        slice.map((f) async => (f.id, await probeFriendPresence(f))),
      );
      for (final o in outcomes) {
        result[o.$1] = o.$2;
      }
    }
    return result;
  }

  /// Platform tag sent with update requests and used to pick the right
  /// artifact type. Strictly self-scoped: each build only serves its own
  /// platform's packages (鍚勭増鏈彧璐熻矗鏈増鐗堟湰鏇存柊) 鈥?android 鈫?APK, windows 鈫?EXE/ZIP.
  String get myPlatform => Platform.isAndroid ? 'android' : 'windows';

  /// Receiver-initiated manual update fetch (no auto-push): asks [friend] for
  /// its newest update package for my platform newer than my version. On a
  /// positive [UpdateRequestResult.ok] the friend streams the package right
  /// after replying; the inbound fileOffer is auto-accepted (matches
  /// [isAwaitingUpdateFrom] + a `wave_*` package name).
  Future<UpdateRequestResult> requestFriendUpdate(
    Friend friend, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (_endpoint == null || _secretKey == null) {
      return const UpdateRequestResult(ok: false, reason: '鏈嶅姟灏氭湭灏辩华');
    }
    if (friend.id.isEmpty) {
      return const UpdateRequestResult(ok: false, reason: '濂藉弸淇℃伅鏃犳晥');
    }
    try {
      final conn = await _friendConnection(friend.id);
      final (tx, rx) = await conn.openBi().timeout(timeout);
      final req = SignedMessage.sign(_secretKey!, MessageBody.updateRequest(
          platform: myPlatform, currentVersion: appVersion));
      await _writeMsg(tx, req);

      final replyBytes = await _readMsg(rx).timeout(timeout);
      if (replyBytes == null) {
        return const UpdateRequestResult(
            ok: false, reason: '濂藉弸鏈搷搴旓紙瀵规柟鍙兘鐗堟湰杩囨棫锛屼笉鏀寔璇ュ姛鑳斤級');
      }
      final (_, body) = SignedMessage.verify(replyBytes);
      if (body.kind != MessageBodyKind.updateReply) {
        return const UpdateRequestResult(ok: false, reason: '濂藉弸鍥炲寮傚父');
      }
      if (body.updateOk != true) {
        return UpdateRequestResult(
            ok: false, reason: body.updateReason ?? '好友未提供更新包');
      }
      markSeen(friend.id);
      _awaitingUpdate[friend.id] = (
        fileName: body.updateFileName ?? '',
        until: DateTime.now().add(_awaitingUpdateTtl),
      );
      return UpdateRequestResult(
        ok: true,
        version: body.updateVersion,
        fileName: body.updateFileName,
        size: body.updateSize,
      );
    } catch (e) {
      _log('requestFriendUpdate failed: $e');
      return UpdateRequestResult(ok: false, reason: '璇锋眰澶辫触锛?e');
    }
  }

  // 鈹€鈹€ Moments (pull-based social feed) 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

  static const Duration _momentRequestTimeout = Duration(seconds: 30);

  String get _myHex =>
      _endpoint?.id.toHex() ?? _identityManager.currentIdentity?.publicKeyHex ?? '';

  /// Publishes a post to my own local timeline. No notification is pushed to
  /// any friend 鈥?they pull it when they next enter Moments. [images] are
  /// downscaled/re-encoded, stored as the post's image bytes and returned.
  /// Returns the created post record (or null when identity is missing).
  Future<Map<String, dynamic>?> publishMoment(
      String text, List<Uint8List> images) async {
    if (_secretKey == null || _myHex.isEmpty) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final postId = '${now}_${Random().nextInt(0xFFFFFFFF).toRadixString(16)}';

    final count = images.length.clamp(0, _momentMaxImages).toInt();
    for (var i = 0; i < count; i++) {
      final bytes = images[i];
      Uint8List out;
      try {
        final prepared = await prepareImageForSend(bytes, 'moment.jpg',
            maxDim: 1280, compactBytes: 512 * 1024, forceJpg: true);
        out = prepared?.data ?? bytes;
      } catch (_) {
        out = bytes;
      }
      await MomentsStore.saveImage(_myHex, postId, i, out);
    }

    final post = <String, dynamic>{
      'id': postId,
      'text': text,
      'imageCount': count,
      'ts': now,
      'likes': <Map<String, dynamic>>[],
      'comments': <Map<String, dynamic>>[],
    };

    final mine = await MomentsStore.loadMyMoments();
    mine.insert(0, post);
    if (mine.length > 100) mine.removeRange(100, mine.length);
    await MomentsStore.saveMyMoments(mine);
    _emitMomentEvent('me');
    _log('Moment published: $postId ($count images)');
    return post;
  }

  /// Deletes one of my posts locally and records its id so friends can drop
  /// their cached copies on their next pull.
  Future<void> deleteMyMoment(String postId) async {
    final mine = await MomentsStore.loadMyMoments();
    final removed = mine.where((p) => p['id'] == postId).toList();
    mine.removeWhere((p) => p['id'] == postId);
    await MomentsStore.saveMyMoments(mine);
    if (removed.isNotEmpty) {
      final deleted = await MomentsStore.loadDeletedMyPostIds();
      if (!deleted.contains(postId)) {
        deleted.insert(0, postId);
        if (deleted.length > 50) deleted.removeRange(50, deleted.length);
        await MomentsStore.saveDeletedMyPostIds(deleted);
      }
      final imageCount = removed.first['imageCount'] as int? ?? 0;
      await MomentsStore.deletePostImages(_myHex, postId, imageCount);
    }
    _emitMomentEvent('me');
  }

  /// Pulls a friend's posts. With [before] set this pages further back in the
  /// timeline; otherwise it pulls everything newer than the stored cursor.
  /// Results are merged into the local cache and emitted on [momentEventStream].
  Future<void> fetchFriendMoments(Friend friend, {int? before}) async {
    if (_endpoint == null || _secretKey == null || friend.id.isEmpty) return;
    _beginOp(friend.id);
    try {
      final conn = await _friendConnection(friend.id);
      final (tx, rx) = await conn.openBi().timeout(_momentRequestTimeout);
      final since = before == null ? await MomentsStore.loadCursor(friend.id) : null;
      final body = MessageBody.momentFetch(
          since: since, before: before, limit: 20);
      await _writeMsg(tx, SignedMessage.sign(_secretKey!, body));

      final reply = await _readMsg(rx).timeout(_momentRequestTimeout);
      if (reply == null) return;
      markSeen(friend.id);
      final (_, resp) = SignedMessage.verify(reply);
      if (resp.kind != MessageBodyKind.momentFeed) return;

      await _mergeFriendMoments(
          friend.id, resp.moments ?? const [], resp.deletedIds ?? const []);
      final posts = await MomentsStore.loadFriendMoments(friend.id);
      if (posts.isNotEmpty) {
        final maxTs = posts.map((p) => p['ts'] as int? ?? 0).fold<int>(0, max);
        await MomentsStore.saveCursor(friend.id, maxTs);
      }
      _emitMomentEvent(friend.id);
    } catch (e) {
      _dropFriendConnection(friend.id);
      _log('Fetch moments from ${friend.name} failed: $e');
    } finally {
      _endOp(friend.id);
    }
  }

  /// Merges [postInfos] into the friend's cached timeline and applies the
  /// sender's deleted-post ids. Kept sorted newest-first.
  Future<void> _mergeFriendMoments(String friendHex,
      List<MomentPostInfo> postInfos, List<String> deletedIds) async {
    final existing = await MomentsStore.loadFriendMoments(friendHex);
    final deletedSet = deletedIds.toSet();

    final byId = <String, Map<String, dynamic>>{
      for (final p in existing)
        if (p['id'] is String && !deletedSet.contains(p['id'])) p['id'] as String: p,
    };
    // A re-pulled (possibly edited) copy overwrites the cached one. Local
    // interaction state (my like/comments, plus replies the author pushed
    // back to me) is carried over so a refresh doesn't wipe them.
    for (final p in postInfos) {
      final cached = existing.where((e) => e['id'] == p.id).toList();
      final prev = cached.isEmpty ? null : cached.first;
      byId[p.id] = {
        'id': p.id,
        'text': p.text,
        'imageCount': p.imageCount,
        'ts': p.ts,
        'myLike': prev?['myLike'] ?? false,
        'myComments': prev?['myComments'] ?? <Map<String, dynamic>>[],
        if (prev?['comments'] != null) 'comments': prev!['comments'],
      };
    }
    if (deletedSet.isNotEmpty) {
      for (final id in byId.keys.where(deletedSet.contains)) {
        byId.remove(id);
      }
      // Drop any cached images of posts the author deleted.
      for (final id in deletedSet) {
        final removed = existing.where((p) => p['id'] == id).toList();
        if (removed.isEmpty) continue;
        await MomentsStore.deletePostImages(
            friendHex, id, removed.first['imageCount'] as int? ?? 0);
      }
    }

    var merged = byId.values.toList()
      ..sort((a, b) => (b['ts'] as int? ?? 0).compareTo(a['ts'] as int? ?? 0));
    if (merged.length > 300) merged = merged.sublist(0, 300);
    await MomentsStore.saveFriendMoments(friendHex, merged);
  }

  /// Returns the cached bytes for a post image, fetching them from the author
  /// on demand when not present locally.
  Future<Uint8List?> fetchMomentImage(
      String friendHex, String postId, int index, {String? authorHex}) async {
    final owner = authorHex ?? friendHex;
    if (await MomentsStore.imageExists(owner, postId, index)) {
      try {
        return await (await MomentsStore.imageFile(owner, postId, index))
            .readAsBytes();
      } catch (_) {
        return null;
      }
    }
    if (_endpoint == null || _secretKey == null) return null;
    return _withMomentImageSlot(
        () => _fetchMomentImageNetwork(friendHex, postId, index, owner));
  }

  Future<Uint8List?> _fetchMomentImageNetwork(
      String friendHex, String postId, int index, String owner) async {
    _beginOp(owner);
    try {
      final conn = await _friendConnection(friendHex);
      final (tx, rx) = await conn.openBi().timeout(_momentRequestTimeout);
      await _writeMsg(
          tx, SignedMessage.sign(_secretKey!, MessageBody.momentImage(postId, index)));
      final reply = await _readMsg(rx).timeout(_momentRequestTimeout);
      if (reply == null) return null;
      markSeen(friendHex);
      final (_, resp) = SignedMessage.verify(reply);
      if (resp.kind != MessageBodyKind.momentImageData) return null;
      final data = resp.momentData;
      if (data == null || data.isEmpty) return null;
      await MomentsStore.saveImage(owner, postId, index, data);
      _emitMomentEvent('image:$postId:$index');
      return data;
    } catch (e) {
      _dropFriendConnection(friendHex);
      _log('Fetch moment image $postId[$index] failed: $e');
      return null;
    } finally {
      _endOp(owner);
    }
  }

  /// Sends a like (reactType 1) or comment (reactType 2) about a friend's post
  /// to the author. Also records it locally for an optimistic UI update.
  Future<bool> sendMomentReact(Friend friend, String postId, int reactType,
      {String? text}) async {
    if (_endpoint == null || _secretKey == null || friend.id.isEmpty) {
      return false;
    }
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ok = await _momentRequest(friend.id,
        MessageBody.momentReact(postId, reactType, text: text, ts: ts));
    if (ok) {
      await _recordMyReact(friend.id, postId, reactType, text ?? '', ts);
      _emitMomentEvent(friend.id);
    }
    return ok;
  }

  Future<void> _recordMyReact(
      String friendHex, String postId, int reactType, String text, int ts) async {
    try {
      final posts = await MomentsStore.loadFriendMoments(friendHex);
      var changed = false;
      for (final p in posts) {
        if (p['id'] != postId) continue;
        changed = true;
        if (reactType == 1) {
          p['myLike'] = true;
        } else if (reactType == 2) {
          final comments = (p['myComments'] as List?)?.cast<Map<String, dynamic>>() ??
              <Map<String, dynamic>>[];
          comments.add({'text': text, 'ts': ts});
          p['myComments'] = comments;
        }
      }
      if (changed) await MomentsStore.saveFriendMoments(friendHex, posts);
    } catch (_) {}
  }

  /// Author replies to a comment on their own post. Sends the reply to the
  /// original commenter as a normal comment (reactType 2), so they can see it.
  /// Also records the reply locally with a [replyToTs]/[replyToName] reference
  /// so the author's timeline shows the thread ("鍥炲 X").
  Future<bool> sendMomentReply(
    Friend commenter,
    String postId,
    String text, {
    required int replyToTs,
    required String replyToName,
  }) async {
    if (_endpoint == null || _secretKey == null || commenter.id.isEmpty) {
      return false;
    }
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ok = await _momentRequest(
        commenter.id, MessageBody.momentReact(postId, 2, text: text, ts: ts));
    if (ok) {
      await _recordAuthorReply(
          postId, text, ts, replyToTs: replyToTs, replyToName: replyToName);
      _emitMomentEvent(commenter.id);
    }
    return ok;
  }

  Future<void> _recordAuthorReply(
    String postId,
    String text,
    int ts, {
    required int replyToTs,
    required String replyToName,
  }) async {
    try {
      final posts = await MomentsStore.loadMyMoments();
      var changed = false;
      for (final p in posts) {
        if (p['id'] != postId) continue;
        changed = true;
        final comments = (p['comments'] as List?)?.cast<Map<String, dynamic>>() ??
            <Map<String, dynamic>>[];
        comments.add({
          'hex': _myHex,
          'text': text,
          'ts': ts,
          'replyTo': replyToTs,
          'replyToName': replyToName,
        });
        p['comments'] = comments;
      }
      if (changed) await MomentsStore.saveMyMoments(posts);
    } catch (_) {}
  }

  /// Generic one-shot request expecting a plain "ok" ack back.
  Future<bool> _momentRequest(String friendHex, MessageBody body) async {
    try {
      final conn = await _friendConnection(friendHex);
      final (tx, rx) = await conn.openBi().timeout(_momentRequestTimeout);
      await _writeMsg(tx, SignedMessage.sign(_secretKey!, body));
      final ack = await _readMsg(rx).timeout(_ackTimeout);
      return ack != null;
    } catch (e) {
      _dropFriendConnection(friendHex);
      _log('Moment request failed: $e');
      return false;
    }
  }

  // Incoming handlers ---------------------------------------------------

  Future<void> _handleMomentFetch(
      String fromHex, MessageBody body, SendStream tx) async {
    try {
      final mine = await MomentsStore.loadMyMoments();
      final since = body.since;
      final before = body.before;
      final limit = (body.limit ?? 20).clamp(1, 100);

      List<Map<String, dynamic>> filtered;
      if (since != null) {
        filtered = mine.where((p) => (p['ts'] as int? ?? 0) > since).toList();
      } else if (before != null) {
        filtered =
            mine.where((p) => (p['ts'] as int? ?? 0) < before).toList();
        if (filtered.length > limit) filtered = filtered.sublist(0, limit);
      } else {
        filtered = mine.take(limit).toList();
      }

      final postInfos = [
        for (final p in filtered)
          MomentPostInfo(
            p['id'] as String? ?? '',
            p['text'] as String? ?? '',
            (p['imageCount'] as int? ?? 0).clamp(0, _momentMaxImages).toInt(),
            p['ts'] as int? ?? 0,
          ),
      ];
      final deleted = await MomentsStore.loadDeletedMyPostIds();
      final feed = MessageBody.momentFeed(postInfos,
          deletedIds: deleted.take(50).toList());
      await _writeMsg(tx, SignedMessage.sign(_secretKey!, feed));
    } catch (e) {
      _log('_handleMomentFetch error: $e');
      try {
        await tx.finish();
      } catch (_) {}
    }
  }

  Future<void> _handleMomentImageRequest(
      String fromHex, MessageBody body, SendStream tx) async {
    try {
      final postId = body.momentId ?? '';
      final index = body.momentIndex ?? 0;
      Uint8List data = Uint8List(0);
      final mine = await MomentsStore.loadMyMoments();
      final post = mine.where((p) => p['id'] == postId).toList();
      if (post.isNotEmpty && index < (post.first['imageCount'] as int? ?? 0)) {
        try {
          final f = await MomentsStore.imageFile(_myHex, postId, index);
          if (await f.exists()) {
            data = await f.readAsBytes();
          }
        } catch (_) {}
      }
      await _writeMsg(
          tx, SignedMessage.sign(_secretKey!, MessageBody.momentImageData(postId, index, data)));
    } catch (e) {
      _log('_handleMomentImageRequest error: $e');
      try {
        await tx.finish();
      } catch (_) {}
    }
  }

  Future<void> _handleMomentFeed(
      String fromHex, MessageBody body, SendStream tx) async {
    try {
      await _mergeFriendMoments(
          fromHex, body.moments ?? const [], body.deletedIds ?? const []);
      _emitMomentEvent(fromHex);
    } catch (e) {
      _log('_handleMomentFeed error: $e');
    }
    await _sendAck(tx);
  }

Future<void> _handleMomentImageData(
    String fromHex, MessageBody body, SendStream tx) async {
    final postId = body.momentId ?? '';
    final index = body.momentIndex ?? 0;
    final data = body.momentData;
    if (data != null && data.isNotEmpty && data.length <= _momentImageMaxBytes) {
      await MomentsStore.saveImage(fromHex, postId, index, data);
      _emitMomentEvent('image:$postId:$index');
    }
    await _sendAck(tx);
  }

  Future<void> _handleMomentReact(
      String fromHex, MessageBody body, SendStream tx) async {
    try {
      final reactType = body.reactType ?? 0;
      final mine = await MomentsStore.loadMyMoments();
      var changed = false;
      for (final p in mine) {
        if (p['id'] != body.momentId) continue;
        changed = true;
        if (reactType == 1) {
          final likes = (p['likes'] as List?)
                  ?.cast<Map<String, dynamic>>() ??
              <Map<String, dynamic>>[];
          if (!likes.any((l) => l['hex'] == fromHex)) {
            likes.add({'hex': fromHex});
          }
          p['likes'] = likes;
        } else if (reactType == 2) {
          final comments = (p['comments'] as List?)
                  ?.cast<Map<String, dynamic>>() ??
              <Map<String, dynamic>>[];
          comments.add({
            'hex': fromHex,
            'text': body.text ?? '',
            'ts': body.momentTs ?? DateTime.now().millisecondsSinceEpoch,
          });
          p['comments'] = comments;
        }
      }
      if (changed) {
        await MomentsStore.saveMyMoments(mine);
        _emitMomentEvent('react:${body.momentId}:$reactType:$fromHex');
        await _sendAck(tx);
        return;
      }
      // The post isn't mine: this is the author replying to a comment I left
      // on their post. Record it into my cached copy of the author's post so
      // the reply surfaces in the Moments feed.
      final friendPosts = await MomentsStore.loadFriendMoments(fromHex);
      var recorded = false;
      for (final p in friendPosts) {
        if (p['id'] != body.momentId) continue;
        recorded = true;
        if (reactType == 2) {
          final comments = (p['comments'] as List?)
                  ?.cast<Map<String, dynamic>>() ??
              <Map<String, dynamic>>[];
          comments.add({
            'hex': fromHex,
            'text': body.text ?? '',
            'ts': body.momentTs ?? DateTime.now().millisecondsSinceEpoch,
          });
          p['comments'] = comments;
        }
      }
      if (recorded) {
        await MomentsStore.saveFriendMoments(fromHex, friendPosts);
        _emitMomentEvent('react:${body.momentId}:$reactType:$fromHex');
      }
      await _sendAck(tx);
    } catch (e) {
      _log('_handleMomentReact error: $e');
    }
    await _sendAck(tx);
  }

  Future<void> _handleMomentDelete(
      String fromHex, MessageBody body, SendStream tx) async {
    final postId = body.momentId ?? '';
    if (postId.isNotEmpty) {
      await _mergeFriendMoments(fromHex, const [], [postId]);
      _emitMomentEvent(fromHex);
    }
    await _sendAck(tx);
  }

  // 鈹€鈹€ Voice call 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

  static const Duration _callRingTimeout = Duration(seconds: 30);

  /// Capture PCM16 is coalesced into fixed-size windows before encoding. 320
  /// samples = 40 ms @ 8 kHz (~25 frames/sec), a steady cadence regardless of
  /// the platform capture packets (WaveAudio polls ~10-20 ms bursts), which
  /// cuts per-frame signing/encoding/write overhead ~3-4x.
  static const int _callSendFrameSamples = 320;

  static String _randomCallId() {
    final r = Random().nextInt(0xFFFFFFFF);
    return r.toRadixString(16).padLeft(8, '0');
  }

  String _myNickname() =>
      _identityManager.currentIdentity?.nickname ?? 'Unknown';

  String _myShortId() =>
      _identityManager.currentIdentity?.shortId ?? '';

  void _emitCallEvent({String? reason}) {
    _callEventController.add(CallEvent(
      phase: _callPhase,
      peerName: _callPeerName,
      peerShortId: _callPeerShortId,
      callId: _callId,
      reason: reason,
    ));
  }

  Future<bool> _trySendCallFrame(MessageBody body) async {
    final tx = _callTx;
    if (tx == null || _secretKey == null) return false;
    try {
      final signed = SignedMessage.sign(_secretKey!, body);
      return await _writeFrameLocked(tx, signed);
    } catch (_) {
      return false;
    }
  }

  /// Local hangup: signal any pending wait so a blocked read can be
  /// interrupted and the call torn down. Recreated at each call start.
  late Completer<void> _callHangupSignal;

  /// Serializes frame writes on the active call's send stream. Audio frames
  /// are fired from the capture callback with `unawaited`, so multiple
  /// `_writeFrame` calls (len + payload, two separate `writeAll`s) can
  /// otherwise interleave and corrupt the byte stream 鈥?which both garbles
  /// audio and silently swallows hangup frames. Appending each write as a
  /// link in this future chain keeps every frame atomic on the wire.
  Future<void> _callWriteTail = Future<void>.value();

  /// Pending capture PCM16 samples awaiting coalescing into frames
  /// (see [_callSendFrameSamples]). Reset at each media session start.
  List<int> _callSendAccumulator = [];

  /// True while a coalesced frame's write chain is still in flight. When the
  /// link can't keep up, whole windows are shed instead of queuing, bounding
  /// call latency instead of letting frames pile up and burst out (stutter).
  bool _callFrameInFlight = false;

  /// The user decided to hang up / cancel / decline. Safe to call in any phase.
  Future<void> endActiveCall() async {
    final phase = _callPhase;
    if (phase == CallPhase.active) {
      _callLocalHangup = true;
      await _trySendCallFrame(MessageBody.callHangup(_callId ?? ''));
      // Close our half of the stream so the peer's media loop reaches EOF
      // and tears down even if the hangup frame itself was ever lost.
      try {
        await _callTx?.finish();
      } catch (_) {}
      _callHangupSignal.complete();
      await _endCallInternal('Ended');
    } else if (phase == CallPhase.outgoingRing) {
      _callLocalHangup = true;
      _callHangupSignal.complete();
      // Ringing loop will send the hangup once it notices.
    } else if (phase == CallPhase.incomingRing) {
      answerIncomingCall(false);
    }
  }

  /// The user answered (or dismissed / auto-rejected) a pending incoming call.
  void answerIncomingCall(bool accept) {
    final c = _incomingAnswer;
    if (c != null && !c.isCompleted) {
      c.complete(accept);
    }
  }

  Future<void> startCall(Friend friend) async {
    if (_endpoint == null || _secretKey == null) return;
    if (isInCall) return;

    final callId = _randomCallId();
    _callPhase = CallPhase.outgoingRing;
    _callId = callId;
    _callPeerName = friend.displayName;
    _callPeerShortId =
        friend.shortId.isNotEmpty ? friend.shortId : friend.displayName;
    _callLocalHangup = false;
    _callHangupSignal = Completer<void>();
    _callWriteTail = Future<void>.value();
    _emitCallEvent();

    final addr = _addrCache[friend.id] ?? _relayAddrForPeer(friend.id);
    _cacheAddr(friend.id, addr);

    SendStream? tx;
    RecvStream? rx;
    try {
      final conn = await _endpoint!.connect(addr, utf8.encode(moonDmAlpn));
      final bi = await conn.openBi();
      tx = bi.$1;
      rx = bi.$2;
      _callTx = tx;
      _callRx = rx;

      final invite = SignedMessage.sign(_secretKey!,
          MessageBody.callInvite(callId, _myNickname(), _myShortId()));
      await _writeFrame(tx, invite);

      while (_callPhase == CallPhase.outgoingRing) {
        if (_callLocalHangup) {
          await _trySendCallFrame(MessageBody.callHangup(callId));
          try {
            await _callTx?.finish();
          } catch (_) {}
          break;
        }
        Uint8List? frame;
        try {
          frame = await Future.any([
            _readMsg(rx),
            _callHangupSignal.future.then((_) => null),
          ]).timeout(_callRingTimeout);
        } catch (_) {
          frame = null;
        }
        if (_callLocalHangup) break;
        if (frame == null) {
          _endCallInternal('No answer');
          return;
        }
        try {
          final (_, body) = SignedMessage.verify(frame);
          if (body.kind == MessageBodyKind.callAccept) {
            _callConnected = true;
            _callPhase = CallPhase.active;
            _emitCallEvent();
            await _runMediaSession();
            return;
          } else if (body.kind == MessageBodyKind.callReject) {
            _endCallInternal(body.callReason ?? 'Declined');
            return;
          } else if (body.kind == MessageBodyKind.callBusy) {
            _endCallInternal('Busy');
            return;
          }
        } catch (_) {
          _endCallInternal('Call error');
          return;
        }
      }
      _endCallInternal('Cancelled');
    } catch (e) {
      _log('Call to ${friend.name} failed: $e');
      _endCallInternal('Call failed');
    } finally {
      tx = null;
      rx = null;
    }
  }

  Future<void> _runMediaSession() async {
    final audio = CallAudioIO();
    _callAudio = audio;
    _callSeq = 0;
    _callSendAccumulator = [];
    _callFrameInFlight = false;
    try {
      await audio.start(onCapture: (pcm) {
        _enqueueCallCapture(pcm);
      });
    } catch (e) {
      _log('Audio session failed to start: $e');
      _endCallInternal('Audio unavailable');
      return;
    }
    _log('Media session started');

    int? lastSeq;
    var frameCount = 0;
    var playCount = 0;
    while (_callPhase == CallPhase.active && !_callLocalHangup) {
      final rx = _callRx;
      if (rx == null) {
        _log('Media: rx is null, leaving');
        break;
      }
      Uint8List? frame;
      try {
        frame = await Future.any([
          _readMsg(rx),
          _callHangupSignal.future.then((_) => null),
        ]);
      } catch (e, st) {
        _log('Media: readMsg error: $e');
        _log('Media: readMsg stack: ${st.toString().split('\n').take(4).join(' | ')}');
        break;
      }
      if (_callLocalHangup) break;
      if (frame == null) {
        _log('Call: peer stream closed');
        break;
      }
      try {
        final (_, body) = SignedMessage.verify(frame);
        if (body.kind == MessageBodyKind.callAudio && body.callData != null) {
          frameCount++;
          if (frameCount <= 3 || frameCount % 100 == 0) {
            _log('Media: RX audio #$frameCount bytes=${body.callData!.length}');
          }
          // Mirror the CLI's out-of-order / duplicate sequencing filter
          // (run_media_session): a frame is played only when its seq moves
          // forward within the window and is not a repeat of the last one.
          // Uses `& 0xFFFFFFFF` to mirror Rust's wrapping_sub arithmetic.
          final seq = body.callSeq;
          final isNew = lastSeq == null ||
              (seq != null && (seq - lastSeq) & 0xFFFFFFFF < 1000 && seq != lastSeq);
          if (!isNew) {
            _log('Media: dropping stale audio seq=$lastSeq->$seq');
            continue;
          }
          if (seq != null) lastSeq = seq;
          final pcm = mulawDecodeFrame(body.callData!);
          if (pcm.isEmpty) continue;
          playCount++;
          if (playCount <= 3 || playCount % 100 == 0) {
            _log('Media: play #$playCount samples=${pcm.length}');
          }
          audio.play(pcm);
        } else if (body.kind == MessageBodyKind.callHangup) {
          _log('Call: peer hung up');
          break;
        }
      } catch (_) {
        _log('Media: frame decode error');
      }
    }

    await _endCallInternal(
        _callLocalHangup ? 'Ended' : _callConnected ? 'Call ended' : 'Ended');
  }

  /// Coalesces raw capture PCM16 into fixed-size windows and sends them at a
  /// steady cadence. When the previous window's write is still in flight (the
  /// link is saturated), the oldest whole window is shed instead of queued, so
  /// call latency stays near [_callSendFrameSamples] rather than ballooning.
  void _enqueueCallCapture(Int16List pcm) {
    final acc = _callSendAccumulator;
    acc.addAll(pcm);
    while (acc.length >= _callSendFrameSamples) {
      if (_callFrameInFlight) {
        // Earliest write still pending: dump the oldest window. seq stays
        // monotonic (we still count it), so the peer's windowed filter treats
        // the gap as new audio and just plays a ~40 ms silence gap.
        acc.removeRange(0, _callSendFrameSamples);
        continue;
      }
      final frame =
          Int16List.fromList(acc.sublist(0, _callSendFrameSamples));
      acc.removeRange(0, _callSendFrameSamples);
      unawaited(_sendAudioFrame(frame));
    }
  }

  Future<void> _sendAudioFrame(Int16List pcm) async {
    if (_callPhase != CallPhase.active || _callTx == null) return;
    _callFrameInFlight = true;
    try {
      final boosted = agcBoost(pcm);
      final encoded = mulawEncodeFrame(boosted);
      _callSeq = (_callSeq + 1) & 0xFFFFFFFF;
      await _trySendCallFrame(MessageBody.callAudio(
          _callId ?? '', _callSeq, encoded));
    } catch (_) {} finally {
      _callFrameInFlight = false;
    }
  }

  Future<void> _endCallInternal(String reason) async {
    final wasActive = _callPhase != CallPhase.idle;
    final audio = _callAudio;
    _callAudio = null;
    if (audio != null) {
      try {
        await audio.stop();
        await audio.dispose();
      } catch (_) {}
    }
    _callPhase = CallPhase.idle;
    _callConnected = false;
    _callLocalHangup = false;
    _callTx = null;
    _callRx = null;
    _log('Call ended: $reason');
    if (wasActive) {
      _emitCallEvent(reason: reason);
    }
  }

  /// Handles an incoming CallInvite arriving on a bi-stream. Signaling and
  /// media all share this single stream for the duration of the call.
  Future<void> _handleIncomingCallInvite(
      String fromHex, MessageBody body, SendStream tx, RecvStream rx) async {
    final callId = body.callId ?? '';
    final fromName = body.fromName ?? 'Unknown';
    final fromShortId = body.shortId ?? '';

    if (isInCall) {
      await _trySendCallFrameOn(tx, MessageBody.callBusy(callId));
      return;
    }

    _incomingAnswer = Completer<bool>();
    _callPhase = CallPhase.incomingRing;
    _callId = callId;
    _callPeerName = fromName;
    _callPeerShortId = fromShortId.isNotEmpty ? fromShortId : fromName;
    _callTx = tx;
    _callRx = rx;
    _callLocalHangup = false;
    _callHangupSignal = Completer<void>();
    _callWriteTail = Future<void>.value();
    _emitCallEvent();

    _incomingCallController.add(IncomingCall(
      callId: callId,
      fromName: fromName,
      fromShortId: fromShortId,
    ));

    // Wait for the local user to answer/decline while also monitoring the
    // incoming stream for a caller hangup (matches the CLI's tokio::select!
    // which reads the bi-direction stream during the ring phase and cancels
    // on CallHangup).
    var accept = false;
    var callerHungUp = false;
    final answer = _incomingAnswer;
    if (answer == null) {
      // No completer wired; treat as missed / timed out.
    } else {
      final ringAnswered = Object();
      final ringDeclined = Object();
      while (true) {
        Object? result;
        try {
          result = await Future.any<Object?>([
            _readMsg(rx),
            answer.future.then((v) => v ? ringAnswered : ringDeclined),
          ]).timeout(_callRingTimeout);
        } on TimeoutException {
          accept = false;
          break;
        } catch (_) {
          // Stream closed / read error while ringing: peer gone.
          accept = false;
          break;
        }
        if (identical(result, ringAnswered)) {
          accept = true;
          break;
        }
        if (identical(result, ringDeclined)) {
          accept = false;
          break;
        }
        // A real frame arrived during the ring: only CallHangup is expected
        // (the caller cancelling); anything else is silently ignored.
        if (result is Uint8List) {
          try {
            final (_, body) = SignedMessage.verify(result);
            if (body.kind == MessageBodyKind.callHangup) {
              callerHungUp = true;
              accept = false;
              break;
            }
          } catch (_) {}
        }
      }
    }

    if (callerHungUp) {
      _endCallInternal('Cancelled');
      return;
    }

    if (!accept) {
      await _trySendCallFrameOn(
          tx, MessageBody.callReject(callId, 'no answer'));
      _endCallInternal('Missed call');
      return;
    }

    await _trySendCallFrameOn(tx, MessageBody.callAccept(callId));
    _callConnected = true;
    _callPhase = CallPhase.active;
    _emitCallEvent();
    await _runMediaSession();
  }

  Future<void> _trySendCallFrameOn(
      SendStream tx, MessageBody body) async {
    if (_secretKey == null) return;
    try {
      final signed = SignedMessage.sign(_secretKey!, body);
      await _writeFrame(tx, signed);
    } catch (_) {}
  }

  static const int _fileChunkSize = 1024 * 1024;

  /// Files at or below this size get a full BLAKE3 verification after arrival;
  /// larger ones are trusted on size + contiguous-ranges alone so a giant
  /// transfer can't OOM the phone just to hash it.
  static const int _maxInMemoryHashBytes = 256 * 1024 * 1024;

  /// Number of concurrent bi-streams used to send one file's chunks.
  static const int _fileParallelStreams = 3;

/// How long the sender waits for the receiver to accept/reject the offer
  /// before giving up ("瀵规柟柟鎺ユ敹鍚庡紑濮嬩紶杈? handshake). Kept above the
  /// receiver's [_fileDecisionTimeout] so the receiver always gets to answer
  /// (even "declined after timeout") before the sender bails with a generic
  /// "no response" and re-offers.
  static const Duration _fileOfferAcceptTimeout = Duration(seconds: 150);

  /// How long the sender waits for the final integrity ack after sending done.
  /// Kept well above the receiver's bounded finalize wait (60 s) plus disk
  /// time, so a receiver that is yet to land the file never races the timeout
  /// and triggers an endless outbox retry loop.
  static const Duration _fileFinalAckTimeout = Duration(seconds: 120);

  /// Sends a file to a friend over a dedicated bi-stream (mirrors the CLI's
  /// `send_file`): FileOffer -> FileChunk* -> FileDone -> FileAck.
  Future<FileSendResult> sendFileToFriend(
    Friend friend,
    File file, {
    String? fileName,
    String? transferId,
    void Function(FileTransferProgress)? onProgress,
  }) async {
    var cancelledByUser = false;
    final identity = _identityManager.currentIdentity;
    if (identity == null || _endpoint == null || _secretKey == null) {
      return const FileSendResult(ok: false, cancelled: false);
    }

    final localName = fileName ??
        (file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : 'file');
    final name = localName.isEmpty ? 'file' : localName;
    final size = await file.length();
    final id = transferId ?? DateTime.now().millisecondsSinceEpoch.toString();

    void emit(int done, FileTransferStatus status, {String? error}) {
      final p = FileTransferProgress(
        transferId: id,
        friendId: friend.id,
        direction: FileTransferDirection.send,
        fileName: name,
        total: size,
        done: done,
        status: status,
        error: error,
      );
      _fileTransferController.add(p);
      onProgress?.call(p);
    }

    try {
      _beginOp(friend.id);
      emit(0, FileTransferStatus.transferring);
      final data = await file.readAsBytes();
      final hash = blake3(data);

      final compressedBytes = Uint8List.fromList(gzip.encode(data));
      final compressed = compressedBytes.length < data.length;
      final wire = compressed ? compressedBytes : data;
      _log('File send to ${friend.name}: $name ($size bytes'
          '${compressed ? ', gzip -> ${wire.length} bytes' : ''})');

      final conn = await _friendConnection(friend.id);
      final cachedAddr = _addrCache[friend.id];
      final pathDesc = cachedAddr == null || cachedAddr.ipAddrs.isEmpty
          ? 'relay-only'
          : 'direct+relay (${cachedAddr.ipAddrs.length} ip(s))';
      _log('File send to ${friend.name}: connected ($pathDesc, reused conn)');

      final watch = Stopwatch()..start();
      var sentTotal = 0;

      // Phase 1 鈥?preprocessing is done (hash + gzip) and only the file's
      // metadata is sent: FileOffer alone, then we wait for the receiver's
      // accept/reject before a single chunk goes out.
      final (tx0, rx0) = await conn.openBi();
      final offer = SignedMessage.sign(_secretKey!,
          MessageBody.fileOffer(id, name, size, identity.nickname, compressed: compressed));
      await _writeFrame(tx0, offer);
      _log('File offer sent to ${friend.name}: $name ($size bytes'
          '${compressed ? ', gzip -> ${wire.length} bytes' : ''}); waiting for accept');

      Uint8List? acceptBytes;
      while (true) {
        if (_fileSendIsCancelled(id)) {
          try {
            await _writeFrame(tx0, SignedMessage.sign(
                _secretKey!, MessageBody.fileCancel(id)));
          } catch (_) {}
          cancelledByUser = true;
          emit(0, FileTransferStatus.cancelled);
          return const FileSendResult(ok: false, cancelled: true);
        }
        try {
          acceptBytes = await _readMsg(rx0)
              .timeout(_fileOfferAcceptTimeout, onTimeout: () => null);
        } catch (_) {
          break;
        }
        if (acceptBytes != null) break;
        // timeout: loop again so a pending cancel can interrupt the wait
      }
      if (acceptBytes == null) {
        emit(0, FileTransferStatus.failed, error: 'no response before transfer');
        return const FileSendResult(ok: false, cancelled: false);
      }
      final (_, acceptBody) = SignedMessage.verify(acceptBytes);
      if (acceptBody.kind != MessageBodyKind.fileAck || acceptBody.fileOk != true) {
        emit(0, FileTransferStatus.failed, error: acceptBody.fileError ?? 'rejected');
        _log('File offer rejected by ${friend.name}: ${acceptBody.fileError}');
        return const FileSendResult(ok: false, cancelled: false);
      }
      _log('File offer accepted by ${friend.name}: starting transfer');
      markSeen(friend.id);

      // Phase 2 鈥?the receiver accepted, so stream the chunks in parallel.
      // Worker 0 continues on the same stream that carried the offer.
      Future<bool> worker0() async {
        var offset = 0;
        while (offset < wire.length) {
          // The user pressed Cancel on this outgoing transfer: halt this
          // stream immediately, tell the receiver to discard its .part file,
          // and surface the cancelled state (no more bytes go out).
          if (_fileSendIsCancelled(id)) {
            try {
              await _writeFrame(tx0, SignedMessage.sign(
                  _secretKey!, MessageBody.fileCancel(id)));
            } catch (_) {}
            cancelledByUser = true;
            emit(sentTotal, FileTransferStatus.cancelled);
            return false;
          }
          final end = offset + _fileChunkSize < wire.length
              ? offset + _fileChunkSize
              : wire.length;
          final chunk = Uint8List.sublistView(wire, offset, end);
          await _writeFrame(tx0, SignedMessage.sign(
              _secretKey!, MessageBody.fileChunk(id, offset, chunk)));
          sentTotal += end - offset;
          offset += _fileParallelStreams * _fileChunkSize;
          emit(sentTotal, FileTransferStatus.transferring);
        }
        await _writeFrame(
            tx0, SignedMessage.sign(_secretKey!, MessageBody.fileDone(id, hash)));
        await tx0.finish();

      // The receiver may interleave unrelated frames (presence probes, a stale
      // voice frame, an echoed offer) on this stream between our fileDone and
      // its final ack. Skipping those is harmless and keeps the ack wait honest
      // instead of treating the first non-fileAck frame as a fatal error.
      MessageBody? ackBody;
      final dead = Stopwatch()..start();
      while (ackBody == null) {
        if (_fileSendIsCancelled(id)) {
          try {
            await _writeFrame(tx0, SignedMessage.sign(
                _secretKey!, MessageBody.fileCancel(id)));
          } catch (_) {}
          cancelledByUser = true;
          emit(sentTotal, FileTransferStatus.cancelled);
          return false;
        }
        if (dead.elapsedMilliseconds > _fileFinalAckTimeout.inMilliseconds) {
          emit(0, FileTransferStatus.failed, error: 'no ack received');
          return false;
        }
        final ackBytes = await _readMsg(rx0)
            .timeout(_fileFinalAckTimeout - dead.elapsed);
        if (ackBytes == null) {
          emit(0, FileTransferStatus.failed, error: 'no ack received');
          return false;
        }
        final (_, candidate) = SignedMessage.verify(ackBytes);
        if (candidate.kind != MessageBodyKind.fileAck) {
          _log('File: skipping non-ack frame ${candidate.kind} while '
              'awaiting final ack');
          continue;
        }
        ackBody = candidate;
      }
      if (ackBody != null && ackBody!.kind == MessageBodyKind.fileAck) {
          if (ackBody.fileOk == true) {
            emit(size, FileTransferStatus.done);
            final secs = watch.elapsedMilliseconds / 1000.0;
            final speed = secs > 0 ? size / 1048576 / secs : 0;
            _log('File sent OK to ${friend.name}: $name ($size bytes) '
                'in ${secs.toStringAsFixed(1)}s (${speed.toStringAsFixed(1)} MB/s)');
            return true;
          }
          emit(0, FileTransferStatus.failed, error: ackBody.fileError ?? 'rejected');
          _log('File rejected by ${friend.name}: ${ackBody.fileError}');
          return false;
        }
        emit(0, FileTransferStatus.failed, error: 'unexpected ack');
        return false;
      }

      Future<bool> worker(int w) async {
        final (tx, _) = await conn.openBi();
        var offset = w * _fileChunkSize;
        while (offset < wire.length) {
          // Cancelled mid-stream 鈥?same as worker0: stop, tell the receiver
          // to drop its partial file, and report the cancelled state.
          if (_fileSendIsCancelled(id)) {
            try {
              await _writeFrame(tx, SignedMessage.sign(
                  _secretKey!, MessageBody.fileCancel(id)));
            } catch (_) {}
            cancelledByUser = true;
            emit(sentTotal, FileTransferStatus.cancelled);
            return false;
          }
          final end = offset + _fileChunkSize < wire.length
              ? offset + _fileChunkSize
              : wire.length;
          final chunk = Uint8List.sublistView(wire, offset, end);
          await _writeFrame(tx, SignedMessage.sign(
              _secretKey!, MessageBody.fileChunk(id, offset, chunk)));
          sentTotal += end - offset;
          offset += _fileParallelStreams * _fileChunkSize;
          emit(sentTotal, FileTransferStatus.transferring);
        }
        await tx.finish();
        return true;
      }

      final results = await Future.wait([
        worker0(),
        for (var w = 1; w < _fileParallelStreams; w++) worker(w),
      ]);
      return FileSendResult(
        ok: results.every((r) => r),
        cancelled: cancelledByUser,
      );
    } catch (e) {
      _dropFriendConnection(friend.id);
      _log('sendFileToFriend failed: $e');
      emit(0, FileTransferStatus.failed, error: '$e');
      _statusController.add('File send failed: $e');
      return FileSendResult(ok: false, cancelled: cancelledByUser);
    } finally {
      // Cancel marker must be cleared so a retried (outbox) send of the same
      // transferId is not aborted forever and the set does not leak entries.
      _fileSendCancelled.remove(id);
      _endOp(friend.id);
    }
  }

  /// File transfers whose chunks are still arriving. Parallel senders stream
  /// chunks over several bi-streams on the same connection, so chunk frames
  /// are routed here by [fileId] and written at their (out-of-order) offsets.
  final Map<String, _FileSession> _fileSessions = {};

  /// transferIds the local user asked to abort while they were still being
  /// sent. The in-flight `sendFileToFriend` loops poll this so the parallel
  /// chunk streams halt promptly (instead of running to wire end) and each
  /// worker can tell the receiver with a wire-level fileCancel. Cleared once
  /// the cancelled transfer loop finishes, freeing the transferId to resend.
  final Set<String> _fileSendCancelled = {};

  /// Whether [transferId] is (still) marked for cancellation. The send
  /// workers poll this between chunks so they abort promptly.
  bool _fileSendIsCancelled(String transferId) =>
      _fileSendCancelled.contains(transferId);

  /// Cancels an in-progress outgoing file transfer (the one showing under the
  /// matching [transferId] in the chat). The sender's chunk workers observe
  /// the request on their next iteration, tear down, send a wire-level
  /// fileCancel so the receiver also stops and cleans up its .part file, and
  /// emit [FileTransferStatus.cancelled]. Safe to call before the receiver has
  /// accepted, while chunks are streaming, or more than once (later calls are
  /// no-ops until the transfer finishes).
  void cancelFileSend(String transferId) {
    if (transferId.isEmpty) return;
    _fileSendCancelled.add(transferId);
    // A cancellation must be terminal: drop any queued redelivery of the same
    // transfer, otherwise the outbox re-sends the file every retry tick and
    // the user is stuck in an endless cancel/resend loop.
    final queued = _outbox.where((e) => e['transferId'] == transferId).toList();
    if (queued.isNotEmpty) {
      for (final e in queued) {
        final messageId = e['messageId'] as String?;
        final friendId = e['friendId'] as String? ?? '';
        _outbox.remove(e);
        if (messageId != null) {
          unawaited(_reportOutboxResult(friendId, messageId, false));
        }
      }
      _persistOutbox();
      _log('File send cancelled: dropped ${queued.length} queued '
          'redeliver(ies) for $transferId');
    }
    _log('File send cancel requested for $transferId');
  }

  /// undecided offer never blocks presence probes / calls / other messages.
  Future<void> _openFileSession(
    String fromHex,
    MessageBody body,
    SendStream tx,
    RecvStream rx,
  ) async {
    final fileId = body.fileId ?? '';
    final name = _sanitizeFileName(body.name ?? 'file');
    final size = body.fileSize ?? 0;
    final fromName = body.fromName ?? '';
    if (fileId.isEmpty) {
      await _drainToEof(rx);
      return;
    }
    if (_fileSessions.containsKey(fileId)) {
      try {
        await _writeMsg(tx, SignedMessage.sign(
            _secretKey!, MessageBody.fileAck(fileId, false, 'duplicate transfer')));
      } catch (_) {}
      unawaited(_drainToEof(rx));
      return;
    }
    if (_fileSessions.length >= 4) {
      try {
        await _writeMsg(tx, SignedMessage.sign(
            _secretKey!, MessageBody.fileAck(fileId, false, 'too many concurrent transfers')));
      } catch (_) {}
      unawaited(_drainToEof(rx));
      return;
    }

    var accepted = false;
    var outDir = await _fileSaveDir();
    // Every inbound file goes through an accept/reject decision — a file must
    // never land on disk without the user choosing. (main.dart auto-accepts a
    // previously-requested update package straight into the updates dir;
    // everything else shows an accept/reject dialog.)
    try {
      final decision = await _awaitFileDecision(IncomingFileOffer(
        fileId: fileId,
        fromHex: fromHex,
        fromName: fromName,
        name: name,
        size: size,
        compressed: body.fileCompressed ?? false,
      ));
      if (decision == null) {
        try {
          await _writeMsg(tx, SignedMessage.sign(
              _secretKey!, MessageBody.fileAck(fileId, false, 'declined')));
        } catch (_) {}
        unawaited(_drainToEof(rx));
        return;
      }
      if (!decision.$1) {
        try {
          await _writeMsg(tx, SignedMessage.sign(
              _secretKey!, MessageBody.fileAck(fileId, false, 'declined')));
        } catch (_) {}
        unawaited(_drainToEof(rx));
        _log('File declined from $fromName: $name');
        return;
      }
      final chosen = _fileDecisionPath[fileId];
      if (chosen != null) {
        if (await FileSystemEntity.type(chosen) == FileSystemEntityType.directory) {
          outDir = Directory(chosen);
        } else if (File(chosen).parent.existsSync()) {
          outDir = File(chosen).parent;
        }
      }
      await outDir.create(recursive: true);
      accepted = true;
    } catch (e) {
      try {
        await _writeMsg(tx, SignedMessage.sign(
            _secretKey!, MessageBody.fileAck(fileId, false, '$e')));
      } catch (_) {}
      unawaited(_drainToEof(rx));
      _log('File decision failed: $e');
      return;
    }

    final tmpPath = '${outDir.path}${Platform.pathSeparator}.$name.$fileId.part';
    final finalPath = await _uniquePath(outDir, name);
    try {
      final raf = await File(tmpPath).open(mode: FileMode.write);
      final session = _FileSession(
        fileId: fileId,
        name: name,
        size: size,
        compressed: body.fileCompressed ?? false,
        fromHex: fromHex,
        fromName: fromName,
        tmpPath: tmpPath,
        finalPath: finalPath,
        raf: raf,
        mainTx: tx,
      );
      _fileSessions[fileId] = session;
      _emitFileProgress(session, 0, FileTransferStatus.transferring);
      _log('File offer accepted from $fromName: $name ($size bytes'
          '${session.compressed ? ', gzip' : ''})');

      // Signal the sender to start streaming now that the target is decided.
      // This is what makes the sender wait ("瀵规柟鎺ユ敹鍚庡紑濮嬩紶杈?).
      // NOTE: use _writeFrame, not _writeMsg 鈥?_writeMsg calls tx.finish() which
      // closes the send half of this bi-stream. The same stream must stay writable
      // so _finalizeFileSession can deliver the final success/fileAck afterwards;
      // otherwise the sender never learns the transfer completed.
      await _writeFrame(tx, SignedMessage.sign(
          _secretKey!, MessageBody.fileAck(fileId, true, null)));
      accepted = true;

      // Chunks can already be queued (senders that stream without waiting):
      // drain them now that the session exists.
      unawaited(_drainOfferStream(session, rx));
    } catch (e) {
      _fileDecisions.remove(fileId);
      _fileDecisionPath.remove(fileId);
      // Acknowledge the failure BEFORE draining: the sender may still be in
      // the offer/accept handshake and won't send any more frames, so an
      // eager drain-to-EOF would wait forever and the sender would fall into
      // an endless retry loop.
      try {
        await _writeMsg(tx, SignedMessage.sign(
            _secretKey!, MessageBody.fileAck(fileId, false, '$e')));
      } catch (_) {}
      unawaited(_drainToEof(rx));
      if (!accepted) {
        _log('File receive session error (accepted=no): $e');
      }
    }
  }

  /// Emits an [IncomingFileOffer] for the UI and waits for the user decision.
  /// Returns (accept, ) or null when the offer times out. The chosen target
  /// directory, when any, is stashed in [_fileDecisionPath].
  Future<(bool,)?> _awaitFileDecision(IncomingFileOffer offer) async {
    final completer = Completer<bool>();
    _fileDecisions[offer.fileId] = completer;
    _incomingFileController.add(offer);
    try {
      final accepted =
          await completer.future.timeout(_fileDecisionTimeout, onTimeout: () => false);
      if (!accepted) _fileDecisionPath.remove(offer.fileId);
      return (accepted,);
    } catch (_) {
      _fileDecisions.remove(offer.fileId);
      return null;
    }
  }

  /// Resolves a pending inbound-file decision from the UI.
  void respondIncomingFile(String fileId, bool accepted, {String? savePath}) {
    final completer = _fileDecisions.remove(fileId);
    if (completer == null) return;
    if (savePath != null) {
      _fileDecisionPath[fileId] = savePath;
    }
    completer.complete(accepted);
  }

  /// Reads a parallel chunk stream to EOF, feeding every chunk into [session].
  /// [first] is the already-verified first frame consumed by the accept loop.
  Future<void> _drainChunkStream(_FileSession s, RecvStream rx,
      {MessageBody? first}) async {
    if (first != null) await _appendChunk(s, first);
    await _drainChunkFrames(s, rx);
  }

  /// Reads the offer stream (session chunks + FileDone/FileCancel), then waits
  /// up to 30 s for the parallel streams to deliver their bytes before
  /// finalizing and acking.
  Future<void> _drainOfferStream(_FileSession s, RecvStream rx) async {
    await _drainChunkFrames(s, rx);
    if (s.hash == null && s.lastError == null && !s.cancelled) {
      s.lastError = 'transfer ended before FileDone';
    }
    bool complete() =>
        s.ranges.isContiguousFromZero ||
        (s.ranges.total == 0 && s.doneReached);
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (!complete() && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await _finalizeFileSession(s);
  }

  Future<void> _drainChunkFrames(_FileSession s, RecvStream rx) async {
    try {
      while (true) {
        final frame = await _readMsg(rx);
        if (frame == null) break;
        final (_, b) = SignedMessage.verify(frame);
        if ((b.fileId ?? '') != s.fileId) continue;
        switch (b.kind) {
          case MessageBodyKind.fileChunk:
            await _appendChunk(s, b);
            break;
          case MessageBodyKind.fileDone:
            s.hash ??= b.fileHash;
            s.doneReached = true;
            break;
          case MessageBodyKind.fileCancel:
            s.cancelled = true;
            break;
          default:
            break;
        }
      }
    } catch (e) {
      s.lastError ??= 'stream error: $e';
    }
  }

  Future<void> _appendChunk(_FileSession s, MessageBody b) async {
    final data = b.fileData;
    if (data == null || data.isEmpty) return;
    final off = b.fileOffset ?? 0;
    if (off < 0) {
      s.lastError ??= 'negative chunk offset';
      return;
    }
    s.raf.setPositionSync(off);
    s.raf.writeFromSync(data, 0, data.length);
    s.ranges.add(off, off + data.length);
    if (s.ranges.total > s.lastEmitted) {
      s.lastEmitted = s.ranges.total;
      _emitFileProgress(s, s.ranges.total, FileTransferStatus.transferring);
    }
  }

  /// Drains a stream to EOF without processing (e.g. an unknown transfer id).
  Future<void> _drainToEof(RecvStream rx) async {
    try {
      while (await _readMsg(rx) != null) {}
    } catch (_) {}
  }

  Future<void> _finalizeFileSession(_FileSession s) async {
    _fileSessions.remove(s.fileId);
    await s.raf.flush();
    await s.raf.close();
    var errorMsg = s.lastError;
    try {
      final wireComplete = s.ranges.isContiguousFromZero ||
          (s.ranges.total == 0 && s.doneReached);
      if (wireComplete) {
        // Every byte we need is present. A late stream error on one of the
        // parallel chunk streams (e.g. at EOF) must not abort a whole file
        // whose bytes are already verified contiguous; treat the bytes as truth.
        errorMsg = null;
      }
      if (errorMsg == null && s.cancelled) {
        errorMsg = 'cancelled';
      }
      if (errorMsg == null && !s.doneReached) {
        errorMsg = 'transfer ended before FileDone';
      }
      if (errorMsg == null && !wireComplete) {
        errorMsg = 'incomplete transfer (missing bytes)';
      }
      if (errorMsg == null) {
        // Landing the file in its final home.
        // Compressed: MUST decode to disk regardless of whether a rename
        // succeeds — a straight rename of the wire bytes would leave the
        // (gzip) payload, which then fails the size check. Decoding first
        // keeps peak memory bounded (streamed pipe, no full-file buffer).
        // Non-compressed: a straight move — no read-into-memory-then-write
        // (double buffering a very large file).
        final tmp = File(s.tmpPath);
        try {
          if (s.compressed) {
            await tmp
                .openRead()
                .transform(gzip.decoder)
                .pipe(File(s.finalPath).openWrite());
            try { await tmp.delete(); } catch (_) {}
          } else {
            try {
              await tmp.rename(s.finalPath);
            } catch (_) {
              await tmp.copy(s.finalPath);
              try { await tmp.delete(); } catch (_) {}
            }
          }
        } catch (e) {
          errorMsg ??= 'persist failed: $e';
        }
      }
      if (errorMsg == null) {
        final finalFile = File(s.finalPath);
        final len = await finalFile.length();
        if (len != s.size) {
          errorMsg = 'size mismatch: got $len, expected ${s.size}';
        } else if (s.hash != null && len <= _maxInMemoryHashBytes) {
          // Integrity check is bounded to files we can afford in memory;
          // bigger files are already content-verified by size + contiguous
          // ranges (a 4+ GB file must not OOM the phone to hash).
          final digest = blake3(await finalFile.readAsBytes());
          if (!_listEquals(digest, s.hash!)) {
            errorMsg = 'hash mismatch - file corrupt';
          }
        }
      }
      if (errorMsg != null) {
        try { await File(s.finalPath).delete(); } catch (_) {}
      }
      final ok = errorMsg == null;
      try {
        await _writeMsg(s.mainTx,
            SignedMessage.sign(_secretKey!, MessageBody.fileAck(s.fileId, ok, errorMsg)));
      } catch (_) {}
      if (ok) {
        _emitFileProgress(s, s.size, FileTransferStatus.done);
        _log('File received from ${s.fromName}: ${s.name} (${s.size} bytes) '
            'saved to ${s.finalPath}');
        _fileDownloadController.add(FileDownloaded(
          fromHex: s.fromHex,
          fileName: s.name,
          filePath: s.finalPath,
          fileSize: s.size,
          transferId: s.fileId,
        ));
      } else {
        try { await File(s.tmpPath).delete(); } catch (_) {}
        _emitFileProgress(s, 0, FileTransferStatus.failed, error: errorMsg);
        _log('File receive failed from ${s.fromName}: $errorMsg');
      }
    } catch (e) {
      _log('_finalizeFileSession error: $e');
      try { await File(s.tmpPath).delete(); } catch (_) {}
      try {
        await _writeMsg(s.mainTx, SignedMessage.sign(
            _secretKey!, MessageBody.fileAck(s.fileId, false, '$e')));
      } catch (_) {}
    }
  }

  void _emitFileProgress(_FileSession s, int done, FileTransferStatus status,
      {String? error}) {
    _fileTransferController.add(FileTransferProgress(
      transferId: s.fileId,
      friendId: s.fromHex,
      direction: FileTransferDirection.receive,
      fileName: s.name,
      total: s.size,
      done: done,
      status: status,
      error: error,
    ));
  }

  /// Resolves the destination for received files: the OS **Downloads**
  /// directory when the platform exposes one (that's where users actually
  /// look), falling back to a `wave_files` subfolder in app documents. Files
  /// saved to Downloads are visible in the system file manager; the old
  /// "app private documents" default made received files effectively
  /// unfindable ("鐩綍閲屾壘涓嶅埌鏂囦欢").
  Future<Directory> _fileSaveDir() async {
    // Android: write to the user-visible shared Download first. Scoped
    // storage means [getDownloadsDirectory] only resolves to the app-private
    // sandbox (Android/data/<pkg>/files/Downloads), which the user can't see
    // from Files/Documents; a granted folder permission unlocks the shared
    // path, so prefer it so received files actually show up on disk.
    try {
      final external = await getExternalStorageDirectory();
      if (external != null) {
        final dir = Directory(
            '${external.path}${Platform.pathSeparator}Download${Platform.pathSeparator}wave_files');
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir;
      }
    } catch (_) {}
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        final dir = Directory('${downloads.path}${Platform.pathSeparator}wave_files');
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir;
      }
    } catch (_) {}
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}${Platform.pathSeparator}wave_files');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _imageSaveDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}${Platform.pathSeparator}wave_images');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _imageExt(String? name) {
    if (name == null || name.isEmpty) return 'img';
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return 'img';
    final ext = name.substring(dot + 1);
    if (ext.length > 8 || !RegExp(r'^[A-Za-z0-9]+$').hasMatch(ext)) return 'img';
    return ext;
  }

  /// Sanitizes a peer-supplied file name so it can never escape the intended
  /// save directory: strips path separators, drive roots, `..`, reserved
  /// Windows characters, control chars and leading dots/spaces, and bounds its
  /// length. Anything else (spaces, unicode, multiple dots) is preserved.
  String _sanitizeFileName(String name) {
    var out = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f\x7f]'), '_')
        .replaceAll(RegExp(r'^[.\s]+'), '');
    out = out.replaceAll(RegExp(r'\.{2,}'), '.');
    if (out.isEmpty) out = 'file';
    if (out.length > 180) {
      final dot = out.lastIndexOf('.');
      if (dot > 0) {
        out = '${out.substring(0, 172)}${out.substring(dot)}';
      } else {
        out = out.substring(0, 180);
      }
    }
    return out;
  }

  /// Picks a non-colliding destination path: `name`, then `name (1)`,
  /// `name (2)`, ... so an existing file is never overwritten (File.rename can
  /// fail on Windows when the target already exists).
  Future<String> _uniquePath(Directory dir, String name) async {
    var candidate = '${dir.path}${Platform.pathSeparator}$name';
    var counter = 1;
    while (await File(candidate).exists()) {
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final ext = dot > 0 ? name.substring(dot) : '';
      candidate = '${dir.path}${Platform.pathSeparator}$stem ($counter)$ext';
      counter++;
    }
    return candidate;
  }

  bool _listEquals(List<int> a, List<int>? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> sendFriendRequest(String targetShortId) async {
    final identity = _identityManager.currentIdentity;
    if (identity == null || !_isConnected) return;

    _statusController.add('Looking up #$targetShortId...');
    final entry = await lookupUser(targetShortId);
    if (entry == null) {
      _statusController.add('User #$targetShortId not found offline');
      return;
    }

    final peerHex = entry.id.fold('', (h, b) => '$h${b.toRadixString(16).padLeft(2, '0')}');
    _log('Friend request target: peerHex=${peerHex.substring(0, 16)}..., addr=${entry.addr}');
    final body = MessageBody.friendRequest(identity.nickname, identity.shortId ?? '');

    try {
      if (entry.addr != null) {
        _cacheAddr(peerHex, entry.addr!);
      } else {
        _cacheAddr(peerHex, _relayAddrForPeer(peerHex));
      }
      await _sendToPeer(peerHex, body);
      _statusController.add('Friend request sent to #${entry.shortId}');
    } catch (e) {
      _log('Friend request failed: $e');
      _statusController.add('Friend request failed: $e');
    }
  }

  Future<void> acceptFriendRequest(String friendId) async {
    try {
      await _sendToPeer(friendId, MessageBody.friendAccept());
      _statusController.add('Friend accepted');
    } catch (e) {
      _log('Accept friend failed: $e');
    }
  }

  Future<void> rejectFriendRequest(String friendId) async {
    try {
      await _sendToPeer(friendId, MessageBody.friendReject());
      _statusController.add('Friend rejected');
    } catch (e) {
      _log('Reject friend failed: $e');
    }
  }

  Future<void> removeFriend(String friendId) async {
    try {
      await _sendToPeer(friendId, MessageBody.friendRemove());
      _statusController.add('Friend removed');
    } catch (e) {
      _log('Remove friend failed: $e');
    }
  }

  Future<void> updateNickname(String newName) async {
    await _identityManager.updateNickname(newName);
    if (_endpoint == null || _moonAddr == null) return;

    final identity = _identityManager.currentIdentity;
    if (identity == null) return;

    final idBytes = Uint8List.fromList(_hexToBytes(identity.publicKeyHex));
    final req = MoonDnsRequest.register(idBytes, newName, _endpoint!.addr);
    try {
      final reqBytes = req.encode();
      await _sendDnsRequestToMoon(reqBytes);
    } catch (e) {
      _statusController.add('Update failed: $e');
    }
  }

  /// Notifies all accepted friends of a nickname change (mirrors the CLI's
  /// `NickChanged` behavior), so peers update our stored display name.
  Future<void> sendNicknameChange(String newName, List<Friend> friends) async {
    if (_endpoint == null || _secretKey == null) return;
    final accepted =
        friends.where((f) => f.status == FriendStatus.accepted && f.id.isNotEmpty).toList();
    _log('Sending NickChanged to ${accepted.length} friend(s)...');
    for (final f in accepted) {
      try {
        await _sendToPeer(f.id, MessageBody.nickChanged(newName));
      } catch (e) {
        _log('NickChanged to ${f.name} failed: $e');
      }
    }
  }

  void _cacheAddr(String hex, EndpointAddr addr) {
    _addrCache[hex] = addr;
  }

  void disconnect() {
    _isConnected = false;
    _connectionController.add(false);
    _moonConnection = null;
    _dnsChain = Future.value();
    _connWatchdog?.cancel();
    _connWatchdog = null;
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
    for (final conn in _friendConns.values) {
      try {
        conn.close();
      } catch (_) {}
    }
    _friendConns.clear();
    _friendConnecting.clear();
    _lastSeen.clear();
    _busyOps.clear();
    _nextProbeAt.clear();
    _probeFailCount.clear();
    _endpoint?.close();
    _endpoint = null;
  }

  /// Closes connections a phone has stopped using, so a many-friend install
  /// doesn't accumulate hundreds of idle sockets. A connection is only closed
  /// when the peer has produced/consumed no traffic within [_connIdleReclaim]
  /// and is not mid-connect or inside a busy operation; the next
  /// [_friendConnection] transparently reconnects.
  void _reclaimIdleConnections() {
    if (_friendConns.isEmpty) return;
    final cutoff = DateTime.now().subtract(_connIdleReclaim);
    for (final entry in _friendConns.entries.toList()) {
      final hex = entry.key;
      if (hex.isEmpty) continue;
      if (_friendConnecting.containsKey(hex)) continue;
      if (_isBusy(hex)) continue;
      final seen = _lastSeen[hex];
      if (seen != null && seen.isAfter(cutoff)) continue;
      try {
        entry.value.close();
      } catch (_) {}
      _friendConns.remove(hex);
      _log('Reclaimed idle connection to ${hex.substring(0, 16)}...');
    }
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _friendRequestController.close();
    _connectionController.close();
    _statusController.close();
    _onlineUsersController.close();
    _lookupResultController.close();
    _incomingMessageController.close();
  }

  /// Capped in-memory rolling log.
  static const int _logCap = 4000;
  static final List<String> _logs = [];
  static List<String> get logs => _logs;

  void _log(String msg) {
    final line = '[${DateTime.now().toIso8601String()}] $msg';
    _logs.add(line);
    if (_logs.length > _logCap) {
      _logs.removeRange(0, _logs.length - _logCap);
    }
  }

  Future<void> _writeMsg(SendStream tx, Uint8List data) async {
    final out = Uint8List(4 + data.length);
    final vd = out.buffer.asByteData();
    vd.setUint32(0, data.length, Endian.little);
    out.setRange(4, out.length, data);
    await tx.writeAll(out);
    await tx.finish();
  }

  Future<void> _writeFrame(SendStream tx, Uint8List data) async {
    final out = Uint8List(4 + data.length);
    final vd = out.buffer.asByteData();
    vd.setUint32(0, data.length, Endian.little);
    out.setRange(4, out.length, data);
    await tx.writeAll(out);
  }

  /// _writeFrame behind a strict FIFO lock so concurrent call-path writers
  /// (audio frames from the capture callback, hangup frames from the caller)
  /// can never interleave their 4-byte length header with another frame's
  /// payload. The lock is released even when the write throws, so a failed
  /// write cannot deadlock the chain.
  Future<bool> _writeFrameLocked(SendStream tx, Uint8List data) async {
    final prev = _callWriteTail;
    final release = Completer<void>();
    _callWriteTail = release.future;
    await prev;
    try {
      await _writeFrame(tx, data);
      return true;
    } catch (_) {
      return false;
    } finally {
      release.complete();
    }
  }

  /// Upper bound for any single inbound signed frame. Image messages are the
  /// largest legit body (鈮?[imageMaxBytes] payload + thumbnail + framing);
  /// file transfers stream in 1 MB chunks, so each chunk frame fits easily.
  /// Guarding here (before allocation) blocks an attacker from declaring a
  /// huge length and OOM-killing this app across any bi-stream.
  static const int _maxInboundMsgLen = 16 * 1024 * 1024;

  Future<Uint8List?> _readMsg(RecvStream rx) async {
    final lenBuf = await rx.readExact(4);
    final len = lenBuf.buffer.asByteData().getUint32(0, Endian.little);
    if (len > _maxInboundMsgLen) {
      throw Exception('Inbound frame too large: $len bytes');
    }
    return await rx.readExact(len);
  }

  List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }
}

/// Outcome of a receiver-initiated `requestFriendUpdate` call.
class UpdateRequestResult {
  final bool ok;

  /// Package version the peer will stream (null on failure).
  final String? version;
  final String? fileName;
  final int? size;

  /// Human-readable failure reason (null on success).
  final String? reason;

  const UpdateRequestResult({
    required this.ok,
    this.version,
    this.fileName,
    this.size,
    this.reason,
  });
}

/// Phases of a voice call as seen by the UI layer.
enum CallPhase { idle, outgoingRing, incomingRing, active }

/// UI-facing event describing a change in call state.
class CallEvent {
  final CallPhase phase;
  final String? peerName;
  final String? peerShortId;
  final String? callId;
  final String? reason;

  const CallEvent({
    required this.phase,
    this.peerName,
    this.peerShortId,
    this.callId,
    this.reason,
  });
}

/// An incoming call the UI should prompt the user about.
class IncomingCall {
  final String callId;
  final String fromName;
  final String fromShortId;

  const IncomingCall({
    required this.callId,
    required this.fromName,
    required this.fromShortId,
  });
}

/// In-progress receive side of one file transfer. Chunks may arrive on the
/// offer stream and/or on parallel chunk streams; they are written at their
/// (out-of-order) offsets into [raf] and tracked by [_RangeSet].
class _FileSession {
  final String fileId;
  final String name;
  final int size;
  final bool compressed;
  final String fromHex;
  final String fromName;
  final String tmpPath;
  final String finalPath;
  final RandomAccessFile raf;
  final SendStream mainTx;
  final _RangeSet ranges = _RangeSet();
  bool doneReached = false;
  bool cancelled = false;
  String? lastError;
  Uint8List? hash;
  int lastEmitted = 0;

  _FileSession({
    required this.fileId,
    required this.name,
    required this.size,
    required this.compressed,
    required this.fromHex,
    required this.fromName,
    required this.tmpPath,
    required this.finalPath,
    required this.raf,
    required this.mainTx,
  });
}

/// Tracks covered byte ranges so out-of-order parallel chunks can be proven
/// contiguous (a single range starting at 0 means the wire payload is whole).
class _RangeSet {
  final List<({int start, int end})> _ranges = [];
  int _total = 0;

  int get total => _total;

  bool get isContiguousFromZero =>
      _ranges.length == 1 && _ranges.first.start == 0;

  int get end => _ranges.isEmpty ? -1 : _ranges.last.end;

  void add(int start, int end) {
    if (end <= start) return;
    _ranges.add((start: start, end: end));
    _ranges.sort((a, b) => a.start.compareTo(b.start));
    final merged = <({int start, int end})>[];
    for (final r in _ranges) {
      if (merged.isNotEmpty && r.start <= merged.last.end) {
        final last = merged.last;
        final newEnd = last.end > r.end ? last.end : r.end;
        merged[merged.length - 1] = (start: last.start, end: newEnd);
      } else {
        merged.add((start: r.start, end: r.end));
      }
    }
    _total = 0;
    for (final r in merged) {
      _total += r.end - r.start;
    }
    _ranges
      ..clear()
      ..addAll(merged);
  }
}
