import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_wave/models/message.dart';
import 'package:flutter_wave/models/file_transfer.dart';
import 'package:flutter_wave/providers/app_provider.dart';
import 'package:flutter_wave/theme/app_theme.dart';
import 'package:flutter_wave/services/voice_message_io.dart';
import 'package:flutter_wave/services/gallery_saver.dart';
import 'package:flutter_wave/widgets/voice_waveform.dart';

class MessageBubble extends ConsumerWidget {
  final Message message;
  final bool isLast;

  const MessageBubble({
    super.key,
    required this.message,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfer = message.transferId == null
        ? null
        : ref.watch(fileTransfersProvider)[message.transferId];

    return Align(
      alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          left: message.isMe ? 64 : 0,
          right: message.isMe ? 0 : 64,
          bottom: isLast ? 0 : 8,
        ),
        child: Column(
          crossAxisAlignment: message.isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            message.type == MessageType.image
                ? _buildImageBubble(context)
                : Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: message.isMe
                          ? AppTheme.chatBubbleMe
                          : AppTheme.chatBubbleOther,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: Radius.circular(message.isMe ? 16 : 4),
                        bottomRight: Radius.circular(message.isMe ? 4 : 16),
                      ),
                    ),
                    child: message.type == MessageType.file
                        ? _buildFileBubble(context, ref, transfer)
                        : message.type == MessageType.voice
                            ? _buildVoiceBubble(context)
                            : _buildTextBubble(context),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextBubble(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message.content,
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 4),
        _buildTimestamp(),
      ],
    );
  }

  Widget _buildFileBubble(
    BuildContext context, WidgetRef ref, FileTransferProgress? transfer) {
    final name = message.fileName ?? message.content;
    final size = message.fileSize ?? 0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.insert_drive_file, color: Colors.white70, size: 32),
        const SizedBox(width: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 4),
              if (transfer != null &&
                  transfer.status == FileTransferStatus.transferring) ...[
                LinearProgressIndicator(
                  value: transfer.fraction,
                  minHeight: 4,
                  backgroundColor: Colors.white38,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_formatBytes(transfer.done)} / ${_formatBytes(transfer.total)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ] else if (transfer != null &&
                  transfer.status == FileTransferStatus.failed) ...[
                Text(
                  transfer.error ?? 'Transfer failed',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ] else ...[
                Text(
                  _formatBytes(size),
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
                if (message.filePath != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _fileAction('Open file', () {
                        _openFile(message.filePath!);
                      }),
                      const SizedBox(width: 12),
                      _fileAction('Open folder', () {
                        _openContainingFolder(message.filePath!);
                      }),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (transfer != null &&
            transfer.direction == FileTransferDirection.send &&
            transfer.status == FileTransferStatus.transferring)
          InkWell(
            onTap: () {
              ref.read(irohServiceProvider)
                  .cancelFileSend(message.transferId ?? '');
            },
            borderRadius: BorderRadius.circular(14),
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.close, size: 16, color: Colors.white70),
            ),
          ),
        if (transfer != null && transfer.direction == FileTransferDirection.send)
          _buildStatusIcon(),
      ],
    );
  }

  void _openFile(String path) {
    if (!Platform.isWindows) return;
    try {
      // Launching a document via explorer.exe opens its default handler.
      Process.start('explorer', [path]);
    } catch (_) {}
  }

  void _openContainingFolder(String path) {
    if (!Platform.isWindows) return;
    try {
      // `/select,` + path as two separate args (Process.start quotes the path
      // itself): opens the containing folder with the file highlighted.
      Process.start('explorer', ['/select,', path]);
    } catch (_) {}
  }

  Widget _fileAction(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }

  Widget _buildImageBubble(BuildContext context) {
    final name = message.fileName ?? message.content;
    final path = message.filePath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: GestureDetector(
            onTap: path != null && File(path).existsSync()
                ? () => _previewImage(context, path)
                : null,
            child: path != null && File(path).existsSync()
                ? Image.file(
                    File(path),
                    width: 220,
                    height: 220,
                    fit: BoxFit.cover,
                    cacheWidth: 900,
                    filterQuality: FilterQuality.low,
                    errorBuilder: (_, __, ___) => _brokenImage(),
                  )
                : _brokenImage(),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: message.isMe
                ? Colors.white70
                : Colors.white.withValues(alpha: 0.7),
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 4),
        _buildTimestamp(),
      ],
    );
  }

  void _previewImage(BuildContext context, String path) {
    showDialog(
      context: context,
      barrierColor: Colors.black,
      builder: (dialogContext) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 6,
                child: Center(
                  child: Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (_, __, ___) => _brokenImage(),
                  ),
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.save_alt,
                        color: Colors.white, size: 26),
                    tooltip: 'Save to gallery',
                    onPressed: () async {
                      final where = await GallerySaver.saveImage(path);
                      if (!dialogContext.mounted) return;
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        SnackBar(
                          content: Text(
                            where == null
                                ? 'Save failed'
                                : where == 'gallery'
                                    ? 'Saved to gallery'
                                    : 'Saved: $where',
                          ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white,
                        size: 28),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _brokenImage() {
    return Container(
      width: 220,
      height: 220,
      color: Colors.black12,
      child: Icon(
        Icons.broken_image,
        size: 48,
        color: Colors.white38,
      ),
    );
  }

  Widget _buildVoiceBubble(BuildContext context) {
    return _VoiceBubble(message: message);
  }

  Widget _buildTimestamp() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${message.timestamp.hour.toString().padLeft(2, '0')}:${message.timestamp.minute.toString().padLeft(2, '0')}',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 11,
          ),
        ),
        if (message.isMe) ...[
          const SizedBox(width: 4),
          _buildStatusIcon(),
        ],
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Widget _buildStatusIcon() {
    IconData icon;
    Color color;

    switch (message.status) {
      case MessageStatus.sending:
      case MessageStatus.pending:
        icon = Icons.schedule;
        color = Colors.white.withValues(alpha: 0.6);
        break;
      case MessageStatus.sent:
        icon = Icons.check;
        color = Colors.white.withValues(alpha: 0.7);
        break;
      case MessageStatus.delivered:
        icon = Icons.done_all;
        color = Colors.white.withValues(alpha: 0.7);
        break;
      case MessageStatus.read:
        icon = Icons.done_all;
        color = Colors.white;
        break;
      case MessageStatus.failed:
        icon = Icons.error_outline;
        color = AppTheme.errorColor;
        break;
    }

    return Icon(
      icon,
      size: 14,
      color: color,
    );
  }
}

class _VoiceBubble extends ConsumerStatefulWidget {
  final Message message;
  const _VoiceBubble({required this.message});

  @override
  ConsumerState<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends ConsumerState<_VoiceBubble> {
  final VoiceMessageIO _io = VoiceMessageIO();
  Timer? _playTimer;
  bool _isPlaying = false;
  int _elapsedMs = 0;

  /// 渭-law is 1 byte/sample at 8 kHz, so milliseconds = bytes / 8.
  int get _durationMs => (widget.message.fileSize ?? 0) * 1000 ~/ 8000;

  String get _chatId =>
      widget.message.isMe ? widget.message.receiverId : widget.message.senderId;

  bool get _unplayed => !widget.message.isMe && !widget.message.played;

  int _barCount() {
    final sec = _durationMs ~/ 1000;
    final n = 6 + ((sec.clamp(1, 24)) * 0.7).round();
    return n.clamp(7, 24);
  }

  String _fmt(int ms) {
    final total = (ms / 1000).round();
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      _stopPlayback();
      return;
    }
    final path = widget.message.filePath;
    if (path == null) return;
    try {
      final f = File(path);
      if (!await f.exists()) return;
      if (_unplayed) {
        ref.read(messagesProvider(_chatId).notifier).markPlayed(widget.message.id);
      }
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return;
      await _io.play(bytes);
      if (!mounted) return;
      setState(() {
        _isPlaying = true;
        _elapsedMs = 0;
      });
      _startTicker();
    } catch (_) {}
  }

  void _startTicker() {
    _playTimer?.cancel();
    _playTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) {
        _playTimer?.cancel();
        return;
      }
      final next = _elapsedMs + 100;
      final dur = _durationMs;
      if (dur <= 0 || next >= dur) {
        _stopPlayback();
        return;
      }
      setState(() => _elapsedMs = next);
    });
  }

  void _stopPlayback() {
    _playTimer?.cancel();
    _playTimer = null;
    _io.stopPlayback();
    if (mounted) {
      setState(() {
        _isPlaying = false;
        _elapsedMs = 0;
      });
    }
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    _io.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playColor = Colors.white;
    final dimColor = Colors.white.withValues(alpha: 0.38);
    final progress = _isPlaying
        ? (_durationMs <= 0
            ? 0.0
            : (_elapsedMs / _durationMs).clamp(0.0, 1.0))
        : (_unplayed ? 0.0 : 1.0);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_unplayed) ...[
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.errorColor,
            ),
          ),
          const SizedBox(width: 8),
        ],
        InkWell(
          onTap: _togglePlay,
          borderRadius: BorderRadius.circular(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.message.isMe
                      ? Colors.white24
                      : Colors.black12,
                ),
                child: Icon(
                  _isPlaying ? Icons.pause : Icons.play_arrow,
                  color: playColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              VoiceWaveform(
                color: playColor,
                dimColor: dimColor,
                bars: _barCount(),
                height: 16,
                animate: _isPlaying,
                progress: progress,
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _isPlaying ? _fmt(_elapsedMs) : _fmt(_durationMs),
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            Text(
              '${widget.message.timestamp.hour.toString().padLeft(2, '0')}:'
              '${widget.message.timestamp.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
