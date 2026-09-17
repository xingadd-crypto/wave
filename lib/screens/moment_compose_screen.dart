import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_wave/services/iroh_service.dart';
import 'package:flutter_wave/theme/app_theme.dart';

/// Compose + publish a moments post. Publishing is local-only: friends pull it
/// when they next enter their Moments timeline.
class MomentComposeScreen extends ConsumerStatefulWidget {
  const MomentComposeScreen({super.key});

  @override
  ConsumerState<MomentComposeScreen> createState() => _MomentComposeScreenState();
}

class _MomentComposeScreenState extends ConsumerState<MomentComposeScreen> {
  final TextEditingController _textCtrl = TextEditingController();
  final List<String> _paths = [];

  static const int _maxImages = 9;

  bool _publishing = false;

  Future<void> _pickImages() async {
    final remaining = _maxImages - _paths.length;
    if (remaining <= 0) return;
    final files = await FilePicker.pickFiles(type: FileType.image);
    if (files.isEmpty || !mounted) return;
    for (final f in files) {
      if (f.path == null || _paths.contains(f.path)) continue;
      setState(() => _paths.add(f.path!));
      if (_paths.length >= _maxImages) break;
    }
  }

  Future<void> _publish() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty && _paths.isEmpty) return;
    setState(() => _publishing = true);
    try {
      final images = <Uint8List>[];
      for (final p in _paths) {
        try {
          images.add(await File(p).readAsBytes());
        } catch (_) {}
      }
      await IrohService().publishMoment(text, images);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.primaryColor,
        foregroundColor: Colors.white,
        title: const Text('New Post'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _publishing ? null : _publish,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: _publishing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Post'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          TextField(
            controller: _textCtrl,
            maxLines: 8,
            minLines: 4,
            maxLength: 1000,
            decoration: const InputDecoration(
              hintText: 'Share your thoughts…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in _paths)
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(
                    File(p),
                    width: 96,
                    height: 96,
                    fit: BoxFit.cover,
                  ),
                ),
              if (_paths.length < _maxImages)
                InkWell(
                  onTap: _pickImages,
                  child: Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.add_photo_alternate_outlined),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}