import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'saf_storage.dart';

/// Extracts the JPEG previews embedded in Canon CR3 files and caches them on
/// disk. The cache is keyed by path, size, and modification time so an edited
/// or replaced RAW never reuses a stale preview.
class Cr3PreviewCache {
  Cr3PreviewCache._();

  static final Cr3PreviewCache instance = Cr3PreviewCache._();

  static const _maxConcurrentExtractions = 2;
  static const _maxCachedPreviews = 240;

  final _pending = <String, Future<File?>>{};
  final _failed = <String>{};
  final _waiting = <Completer<void>>[];
  Directory? _directory;
  var _active = 0;

  /// Returns a cached preview JPEG for [filePath], extracting it on demand.
  Future<File?> previewFor(String filePath) {
    final pending = _pending[filePath];
    if (pending != null) return pending;
    final future = _previewFor(filePath);
    _pending[filePath] = future;
    unawaited(future.whenComplete(() => _pending.remove(filePath)));
    return future;
  }

  Future<File?> _previewFor(String filePath) async {
    try {
      final safUri = SafStorage.isUri(filePath);
      final safStat = safUri ? await SafStorage.instance.stat(filePath) : null;
      if (safUri && safStat == null) {
        throw FileSystemException(
          'SAF document is no longer available',
          filePath,
        );
      }
      final stat = safUri ? null : await File(filePath).stat();
      final size = safStat?.length ?? stat!.size;
      final modified =
          safStat?.lastModified ?? stat!.modified.millisecondsSinceEpoch;
      final key = sha1
          .convert(utf8.encode('$filePath|$size|$modified'))
          .toString();
      if (_failed.contains(key)) return null;
      final target = File(
        path.join((await _cacheDirectory()).path, '$key.jpg'),
      );
      if (await target.exists()) return target;

      File? temporarySource;
      final Uint8List? bytes;
      try {
        bytes = await _withSlot(() async {
          if (!safUri) return Isolate.run(() => _extractPreviewBytes(filePath));
          final temporaryDirectory = await getTemporaryDirectory();
          temporarySource = File(
            path.join(temporaryDirectory.path, '$key.cr3'),
          );
          await SafStorage.instance.copyToCache(
            filePath,
            temporarySource!.path,
          );
          final sourcePath = temporarySource!.path;
          return Isolate.run(() => _extractPreviewBytes(sourcePath));
        });
      } finally {
        if (temporarySource != null && await temporarySource!.exists()) {
          await temporarySource!.delete();
        }
      }
      if (bytes == null || bytes.length < 1024) {
        _failed.add(key);
        return null;
      }
      await _write(target, bytes);
      return target;
    } on Object catch (error) {
      debugPrint('[cr3] preview failed for $filePath: $error');
      return null;
    }
  }

  Future<void> _write(File target, Uint8List bytes) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(target.path);
  }

  Future<T> _withSlot<T>(Future<T> Function() task) async {
    if (_active < _maxConcurrentExtractions) {
      _active++;
    } else {
      final completer = Completer<void>();
      _waiting.add(completer);
      await completer.future;
    }
    try {
      return await task();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _active--;
      }
    }
  }

  Future<Directory> _cacheDirectory() async {
    final cached = _directory;
    if (cached != null) return cached;
    Directory directory;
    try {
      final support = await getApplicationSupportDirectory();
      directory = Directory(path.join(support.path, 'cr3-previews'));
    } on Object {
      directory = Directory(
        path.join(Directory.systemTemp.path, 'kinesis-cr3-previews'),
      );
    }
    await directory.create(recursive: true);
    _directory = directory;
    unawaited(_prune(directory));
    return directory;
  }

  /// Keeps the cache from growing without limit across sessions.
  Future<void> _prune(Directory directory) async {
    try {
      final files = await directory
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.jpg'))
          .cast<File>()
          .toList();
      if (files.length <= _maxCachedPreviews) return;
      final entries = await Future.wait([
        for (final file in files)
          file.stat().then((stat) => (file, stat.modified)),
      ]);
      entries.sort((a, b) => a.$2.compareTo(b.$2));
      for (final entry in entries.take(entries.length - _maxCachedPreviews)) {
        await entry.$1.delete();
      }
    } on Object catch (error) {
      debugPrint('[cr3] preview cache prune failed: $error');
    }
  }
}

Uint8List? _extractPreviewBytes(String filePath) {
  try {
    return extractCr3Preview(File(filePath).readAsBytesSync());
  } on FileSystemException {
    return null;
  }
}

/// Finds the largest embedded JPEG at or below 2048px on its long edge. CR3
/// files typically contain a 160x120 thumbnail, a ~1620x1080 preview, and a
/// full-size 6000x4000 JPEG, so this avoids caching several megabytes per shot.
@visibleForTesting
Uint8List? extractCr3Preview(Uint8List bytes) {
  final candidates = <_JpegCandidate>[];
  var searchFrom = 0;
  while (searchFrom < bytes.length - 3) {
    final start = _indexOf(bytes, const [0xFF, 0xD8, 0xFF], searchFrom);
    if (start < 0) break;
    final end = _indexOf(bytes, const [0xFF, 0xD9], start + 3);
    if (end < 0) break;
    final endExclusive = end + 2;
    final dimensions = _jpegDimensions(bytes, start, endExclusive);
    if (dimensions != null) {
      candidates.add(
        _JpegCandidate(
          start: start,
          end: endExclusive,
          width: dimensions.$1,
          height: dimensions.$2,
        ),
      );
    }
    searchFrom = endExclusive;
  }
  if (candidates.isEmpty) return null;

  var pool = candidates
      .where(
        (candidate) => candidate.longSide >= 640 && candidate.longSide <= 2048,
      )
      .toList();
  if (pool.isEmpty) {
    final large = candidates
        .where((candidate) => candidate.longSide > 2048)
        .toList();
    pool = large.isNotEmpty ? large : candidates;
  }
  final best = pool.reduce((a, b) => a.length >= b.length ? a : b);
  return bytes.sublist(best.start, best.end);
}

int _indexOf(Uint8List bytes, List<int> pattern, int start) {
  final first = pattern.first;
  final lastStart = bytes.length - pattern.length;
  for (var index = start; index <= lastStart; index++) {
    if (bytes[index] != first) continue;
    var matched = true;
    for (var offset = 1; offset < pattern.length; offset++) {
      if (bytes[index + offset] != pattern[offset]) {
        matched = false;
        break;
      }
    }
    if (matched) return index;
  }
  return -1;
}

/// Reads the frame size from a JPEG's start-of-frame marker.
(int, int)? _jpegDimensions(Uint8List bytes, int start, int end) {
  var index = start + 2;
  while (index + 1 < end) {
    if (bytes[index] != 0xFF) {
      index++;
      continue;
    }
    var marker = bytes[index + 1];
    while (marker == 0xFF && index + 2 < end) {
      index++;
      marker = bytes[index + 1];
    }
    index += 2;
    if (marker == 0x01 ||
        marker == 0xD8 ||
        marker == 0xD9 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      continue;
    }
    if (index + 1 >= end) return null;
    final length = (bytes[index] << 8) | bytes[index + 1];
    if (length < 2) return null;
    if (_isStartOfFrame(marker)) {
      if (index + 6 >= end) return null;
      final height = (bytes[index + 3] << 8) | bytes[index + 4];
      final width = (bytes[index + 5] << 8) | bytes[index + 6];
      if (width == 0 || height == 0) return null;
      return (width, height);
    }
    index += length;
  }
  return null;
}

bool _isStartOfFrame(int marker) =>
    marker >= 0xC0 &&
    marker <= 0xCF &&
    marker != 0xC4 &&
    marker != 0xC8 &&
    marker != 0xCC;

class _JpegCandidate {
  const _JpegCandidate({
    required this.start,
    required this.end,
    required this.width,
    required this.height,
  });

  final int start;
  final int end;
  final int width;
  final int height;

  int get length => end - start;
  int get longSide => math.max(width, height);
}
