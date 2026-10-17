import 'dart:io';

import 'package:flutter/material.dart';

import '../domain/media.dart';
import '../services/cr3_preview.dart';

/// Renders a media thumbnail, falling back to the JPEG preview embedded in a
/// CR3 when no paired JPEG exists.
class MediaPreview extends StatefulWidget {
  const MediaPreview({
    super.key,
    this.preview,
    this.cr3Path,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.placeholder = const SizedBox.shrink(),
    this.loading,
    this.errorPlaceholder,
  });

  /// A known JPEG/image preview, used directly when present.
  final MediaFile? preview;

  /// A CR3 file to extract an embedded preview from when [preview] is null.
  final String? cr3Path;

  final BoxFit fit;
  final int? cacheWidth;
  final Widget placeholder;
  final Widget? loading;
  final Widget? errorPlaceholder;

  @override
  State<MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<MediaPreview> {
  Future<File?>? _cr3Future;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(MediaPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cr3Path != widget.cr3Path ||
        oldWidget.preview?.path != widget.preview?.path) {
      _start();
    }
  }

  void _start() {
    _cr3Future = widget.preview == null && widget.cr3Path != null
        ? Cr3PreviewCache.instance.previewFor(widget.cr3Path!)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.preview != null) return _image(widget.preview!.path);
    final future = _cr3Future;
    if (future == null) return widget.placeholder;
    return FutureBuilder<File?>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return widget.loading ?? widget.placeholder;
        }
        final file = snapshot.data;
        if (file == null) return widget.placeholder;
        return _image(file.path);
      },
    );
  }

  Widget _image(String path) => Image.file(
    File(path),
    fit: widget.fit,
    width: double.infinity,
    height: double.infinity,
    cacheWidth: widget.cacheWidth,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => widget.errorPlaceholder ?? widget.placeholder,
  );
}
