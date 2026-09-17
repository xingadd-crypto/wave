import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_wave/theme/app_theme.dart';
import 'package:flutter_wave/models/friend.dart';
import 'package:flutter_wave/models/message.dart';
import 'package:flutter_wave/providers/app_provider.dart';
import 'package:flutter_wave/services/voice_message_io.dart';
import 'package:flutter_wave/services/image_message_io.dart';
import 'package:flutter_wave/services/iroh_service.dart';
import 'package:flutter_wave/widgets/message_bubble.dart';
import 'package:flutter_wave/widgets/voice_waveform.dart';
import 'package:path_provider/path_provider.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final Friend friend;

  const ChatScreen({super.key, required this.friend});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  late final StateController<String?> _activeChat;

  bool _recording = false;
  final VoiceMessageIO _voiceIo = VoiceMessageIO();
  Future<({Uint8List mulaw, int durationMs})?> Function()? _stopRecording;
  Timer? _recordTimer;
  int _recordSeconds = 0;

  @override
  void initState() {
    super.initState();
    _activeChat = ref.read(activeChatIdProvider.notifier);
    _activeChat.state = widget.friend.id;
    unawaited(ref.read(irohServiceProvider).prewarmFriend(widget.friend));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(friendsProvider.notifier).clearUnread(widget.friend.id);
        _refreshPresence();
        _scrollToBottom();
      }
    });
  }

  void _refreshPresence() {
    ref.read(friendsProvider.notifier).probePresence();
  }

  void _startCall() {
    ref.read(irohServiceProvider).startCall(widget.friend);
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    if (_activeChat.state == widget.friend.id) {
      _activeChat.state = null;
    }
    _inputFocusNode.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    _voiceIo.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final identity = ref.read(appStateProvider);
    final message = Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: identity.userId ?? '',
      receiverId: widget.friend.id,
      content: text,
      timestamp: DateTime.now(),
      type: MessageType.text,
      isMe: true,
      status: MessageStatus.sending,
    );

    ref.read(messagesProvider(widget.friend.id).notifier).addMessage(message);
    ref.read(friendsProvider.notifier).updateLastMessage(
      widget.friend.id,
      text,
      DateTime.now(),
    );

    _messageController.clear();
    _inputFocusNode.requestFocus();
    _scrollToBottom();

    bool delivered = false;
    try {
      delivered = await ref.read(irohServiceProvider).sendMessageToFriend(
        widget.friend,
        text,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }

    if (mounted) {
      final notifier = ref.read(messagesProvider(widget.friend.id).notifier);
      if (delivered) {
        notifier.updateMessageStatus(message.id, MessageStatus.delivered);
      } else {
        unawaited(ref.read(irohServiceProvider).queueMessageForRetry(
          friendId: widget.friend.id,
          messageId: message.id,
          type: 'text',
          text: text,
        ));
        notifier.updateMessageStatus(message.id, MessageStatus.pending);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Message saved; will send when the friend is online'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      await _finishRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    final stop = await _voiceIo.start();
    if (stop == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start recording')),
        );
      }
      return;
    }
    _stopRecording = stop;
    if (mounted) {
      setState(() {
        _recording = true;
        _recordSeconds = 0;
      });
      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _recording) {
          setState(() => _recordSeconds++);
        }
      });
    }
  }

  Future<void> _cancelRecording() async {
    _recordTimer?.cancel();
    _recordTimer = null;
    final stop = _stopRecording;
    _stopRecording = null;
    if (mounted) setState(() => _recording = false);
    if (stop != null) {
      try {
        await stop();
      } catch (_) {}
    }
  }

  Future<void> _finishRecording() async {
    _recordTimer?.cancel();
    _recordTimer = null;
    setState(() => _recording = false);
    final stop = _stopRecording;
    _stopRecording = null;
    if (stop == null) return;

    final result = await stop();
    if (result == null || result.mulaw.isEmpty) return;
    if (!mounted) return;

    final identity = ref.read(appStateProvider);
    final transferId = DateTime.now().millisecondsSinceEpoch.toString();
    String? savedPath;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory(
        '${appDir.path}${Platform.pathSeparator}wave_files',
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      final path = '${dir.path}${Platform.pathSeparator}voice_$transferId.mulaw';
      await File(path).writeAsBytes(result.mulaw);
      savedPath = path;
    } catch (_) {}

    final message = Message(
      id: 'voice_$transferId',
      senderId: identity.userId ?? '',
      receiverId: widget.friend.id,
      content: '[Voice] ${(result.durationMs / 1000).toStringAsFixed(1)}s',
      timestamp: DateTime.now(),
      type: MessageType.voice,
      isMe: true,
      status: MessageStatus.sending,
      fileName: 'voice.mulaw',
      filePath: savedPath,
      fileSize: result.mulaw.length,
      played: true,
    );

    ref.read(messagesProvider(widget.friend.id).notifier).addMessage(message);
    ref.read(friendsProvider.notifier).updateLastMessage(
      widget.friend.id,
      message.content,
      DateTime.now(),
    );
    _scrollToBottom();

    bool delivered = false;
    try {
      delivered = await ref
          .read(irohServiceProvider)
          .sendVoiceMessage(widget.friend, result.mulaw, result.durationMs);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send voice: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }

    if (mounted) {
      final notifier = ref.read(messagesProvider(widget.friend.id).notifier);
      if (delivered) {
        notifier.updateMessageStatus(message.id, MessageStatus.delivered);
      } else {
        if (savedPath != null) {
          unawaited(ref.read(irohServiceProvider).queueMessageForRetry(
            friendId: widget.friend.id,
            messageId: message.id,
            type: 'voice',
            path: savedPath,
            name: 'voice.mulaw',
            durationMs: result.durationMs,
          ));
          notifier.updateMessageStatus(message.id, MessageStatus.pending);
        } else {
          notifier.updateMessageStatus(message.id, MessageStatus.pending);
        }
      }
    }
  }

  Future<void> _pickAndSendFile() async {
    try {
      final picked = await FilePicker.pickFile();
      if (picked == null) return;
      final path = picked.path;
      if (path == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not access file path')),
          );
        }
        return;
      }

      final file = File(path);
      final size = await file.length();
      final name = picked.name.isEmpty
          ? (file.uri.pathSegments.isNotEmpty
              ? file.uri.pathSegments.last
              : 'file')
          : picked.name;
      final transferId = DateTime.now().millisecondsSinceEpoch.toString();

      final message = Message(
        id: 'file_$transferId',
        senderId: ref.read(appStateProvider).userId ?? '',
        receiverId: widget.friend.id,
        content: '[File] $name',
        timestamp: DateTime.now(),
        type: MessageType.file,
        isMe: true,
        status: MessageStatus.sending,
        fileName: name,
        fileSize: size,
        transferId: transferId,
      );

      ref.read(messagesProvider(widget.friend.id).notifier).addMessage(message);
      ref.read(friendsProvider.notifier).updateLastMessage(
        widget.friend.id,
        '[File] $name',
        DateTime.now(),
      );

      final result = await ref.read(irohServiceProvider).sendFileToFriend(
        widget.friend,
        file,
        fileName: name,
        transferId: transferId,
      );

      if (mounted) {
        final msgs = ref.read(messagesProvider(widget.friend.id).notifier);
        if (result.ok) {
          msgs.updateMessageStatus('file_$transferId', MessageStatus.delivered);
        } else if (result.cancelled) {
          // The user aborted this transfer mid-flight: treat it as terminal so
          // it is never re-queued (which would resend the file indefinitely).
          msgs.updateMessageStatus('file_$transferId', MessageStatus.failed);
        } else {
          unawaited(ref.read(irohServiceProvider).queueMessageForRetry(
            friendId: widget.friend.id,
            messageId: 'file_$transferId',
            type: 'file',
            path: path,
            name: name,
            transferId: transferId,
          ));
          msgs.updateMessageStatus('file_$transferId', MessageStatus.pending);
        }
      }
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send file: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  /// Picks an image, builds a PNG thumbnail (CLI-compatible, ≤32 px) and sends
  /// it as a single signed ImageMessage. Mirrors the CLI's `/img` flow.
  Future<void> _pickAndSendImage() async {
    try {
      final picked = await FilePicker.pickFile(type: FileType.image);
      if (picked == null) return;
      final path = picked.path;
      if (path == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not access file path')),
          );
        }
        return;
      }

      final file = File(path);
      if (await file.length() > IrohService.imageMaxBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Image too large (max 8 MB)')),
          );
        }
        return;
      }
      final bytes = await file.readAsBytes();
      final name = picked.name.isEmpty
          ? (file.uri.pathSegments.isNotEmpty
              ? file.uri.pathSegments.last
              : 'image')
          : picked.name;
      final prepared = await prepareImageForSend(bytes, name);
      if (prepared == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Not a valid image')),
          );
        }
        return;
      }

      final message = Message(
        id: 'img_${DateTime.now().millisecondsSinceEpoch}',
        senderId: ref.read(appStateProvider).userId ?? '',
        receiverId: widget.friend.id,
        content: '[Image] ${prepared.name}',
        timestamp: DateTime.now(),
        type: MessageType.image,
        isMe: true,
        status: MessageStatus.sending,
        fileName: prepared.name,
        fileSize: prepared.data.length,
        filePath: path,
      );

      ref.read(messagesProvider(widget.friend.id).notifier).addMessage(message);
      ref.read(friendsProvider.notifier).updateLastMessage(
        widget.friend.id,
        '[Image] ${prepared.name}',
        DateTime.now(),
      );

      final ok = await ref.read(irohServiceProvider).sendImageMessage(
        widget.friend,
        prepared.data,
        prepared.name,
        prepared.width,
        prepared.height,
        prepared.thumbPng,
      );

      if (mounted) {
        final notifier = ref.read(messagesProvider(widget.friend.id).notifier);
        if (ok) {
          notifier.updateMessageStatus(message.id, MessageStatus.delivered);
        } else {
          unawaited(ref.read(irohServiceProvider).queueMessageForRetry(
            friendId: widget.friend.id,
            messageId: message.id,
            type: 'image',
            path: path,
            name: prepared.name,
          ));
          notifier.updateMessageStatus(message.id, MessageStatus.pending);
        }
      }
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send image: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(messagesProvider(widget.friend.id));
    final friend = ref
        .watch(friendsProvider)
        .where((f) => f.id == widget.friend.id)
        .firstOrNull ??
        widget.friend;

    ref.listen<List<Message>>(messagesProvider(widget.friend.id), (prev, next) {
      if (next.isNotEmpty && (prev == null || next.length > prev.length)) {
        _scrollToBottom();
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              friend.displayName,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            _buildStatusLine(friend),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.call),
            tooltip: 'Call',
            onPressed: _startCall,
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: _showChatOptions,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? _buildEmptyChat()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      return MessageBubble(
                        message: message,
                        isLast: index == messages.length - 1,
                      );
                    },
                  ),
          ),
          _buildMessageInput(),
        ],
      ),
    );
  }

  Widget _buildStatusLine(Friend friend) {
    final shortIdPart = friend.shortId.trim().isNotEmpty
        ? '  #${friend.shortId}'
        : '';
    final statusText =
        friend.isOnline ? 'Online$shortIdPart' : 'Offline$shortIdPart';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(right: 5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: friend.isOnline
                ? AppTheme.successColor
                : AppTheme.textHint,
          ),
        ),
        Flexible(
          child: Text(
            statusText,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: friend.isOnline
                  ? AppTheme.successColor
                  : AppTheme.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyChat() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 60,
            color: AppTheme.textHint.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No messages yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Send a message to start the conversation',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppTheme.textHint,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageInput() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        child: _recording ? _buildRecordingRow() : _buildWriteRow(),
      ),
    );
  }

  Widget _buildWriteRow() {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.attach_file),
          onPressed: _pickAndSendFile,
          tooltip: 'Send file',
        ),
        IconButton(
          icon: const Icon(Icons.image_outlined),
          onPressed: _pickAndSendImage,
          tooltip: 'Send image',
        ),
        Expanded(
          child: TextField(
            controller: _messageController,
            focusNode: _inputFocusNode,
            decoration: InputDecoration(
              hintText: 'Type a message...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              filled: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
            ),
            maxLines: null,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendMessage(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.mic, color: AppTheme.primaryColor),
          tooltip: 'Record voice message',
          onPressed: _toggleRecording,
        ),
        const SizedBox(width: 4),
        Container(
          decoration: const BoxDecoration(
            color: AppTheme.primaryColor,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: const Icon(Icons.send, color: Colors.white),
            onPressed: _sendMessage,
          ),
        ),
      ],
    );
  }

  /// iMessage-style recording HUD: cancel on the left, a live animated
  /// waveform with an elapsed timer in the middle, send on the right.
  Widget _buildRecordingRow() {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.close, color: AppTheme.errorColor),
          tooltip: 'Cancel recording',
          onPressed: _cancelRecording,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Row(
            children: [
              const Expanded(
                flex: 3,
                child: VoiceWaveform(
                  color: AppTheme.primaryColor,
                  dimColor: Color(0x406C63FF),
                  bars: 18,
                  height: 22,
                  animate: true,
                  progress: 1.0,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _recordLabel,
                style: const TextStyle(
                  color: AppTheme.primaryColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Container(
          decoration: const BoxDecoration(
            color: AppTheme.primaryColor,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: const Icon(Icons.send, color: Colors.white),
            tooltip: 'Send voice message',
            onPressed: _toggleRecording,
          ),
        ),
      ],
    );
  }

  String get _recordLabel {
    final m = (_recordSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_recordSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _showChatOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Friend Info'),
              subtitle: Text('#${widget.friend.shortId}'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('Set Note'),
              subtitle: widget.friend.note.isNotEmpty
                  ? Text('"${widget.friend.note}"')
                  : null,
              onTap: () {
                Navigator.pop(context);
                _showEditNoteDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: AppTheme.errorColor),
              title: const Text(
                'Delete Chat',
                style: TextStyle(color: AppTheme.errorColor),
              ),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteChat();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEditNoteDialog() {
    final friend = ref
        .watch(friendsProvider)
        .where((f) => f.id == widget.friend.id)
        .firstOrNull ??
        widget.friend;
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
                ref
                    .read(friendsProvider.notifier)
                    .updateFriendNote(friend.id, controller.text.trim());
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
              ref
                  .read(friendsProvider.notifier)
                  .updateFriendNote(friend.id, controller.text.trim());
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteChat() {
    final friend = ref
        .watch(friendsProvider)
        .where((f) => f.id == widget.friend.id)
        .firstOrNull ??
        widget.friend;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Chat'),
        content: Text('Delete all messages with ${friend.displayName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorColor),
            onPressed: () {
              ref.read(messagesProvider(widget.friend.id).notifier).clearMessages();
              Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
