import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../domain/media.dart';

class MediaService {
  static final _libraryIndexLoads = <String, Future<Set<String>>>{};
  static final _libraryHashesBySize = <String, Map<int, Set<String>>>{};

  static const _extensions = <String, MediaKind>{
    '.jpg': MediaKind.jpeg,
    '.jpeg': MediaKind.jpeg,
    '.cr3': MediaKind.cr3,
    '.png': MediaKind.image,
    '.heic': MediaKind.image,
    '.gif': MediaKind.image,
    '.mp4': MediaKind.video,
    '.mov': MediaKind.video,
  };

  Future<DateTime?> _readCaptureDate(File file, MediaKind kind) async {
    if (kind == MediaKind.cr3 || kind == MediaKind.video) return null;
    try {
      final value = await Isolate.run(
        () => _readExifDateString(file.path, kind == MediaKind.jpeg),
      );
      return value == null ? null : _parseExifDate(value);
    } on Object catch (error) {
      debugPrint(
        '[metadata] could not read capture date for ${file.path}: $error',
      );
    }
    return null;
  }

  DateTime? _parseExifDate(String value) {
    final match = RegExp(
      r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final parts = [
      for (var index = 1; index <= 6; index++) int.parse(match[index]!),
    ];
    final date = DateTime(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    );
    if (date.year != parts[0] ||
        date.month != parts[1] ||
        date.day != parts[2] ||
        date.hour != parts[3] ||
        date.minute != parts[4] ||
        date.second != parts[5]) {
      return null;
    }
    return date;
  }

  Future<List<ReviewItem>> scan(
    String source, {
    Set<String> existingHashes = const {},
  }) async {
    final files = <MediaFile>[];
    await for (final entity in Directory(
      source,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      // FAT/exFAT camera cards copied from macOS can contain AppleDouble
      // metadata sidecars named `._<original-name>` that are not media.
      if (path.basename(entity.path).startsWith('._')) continue;
      if (_inTrashFolder(entity.path)) continue;
      final kind = _extensions[path.extension(entity.path).toLowerCase()];
      if (kind != null) {
        final stat = await entity.stat();
        final file = MediaFile(
          path: entity.path,
          kind: kind,
          sizeBytes: stat.size,
          captureDate: await _readCaptureDate(entity, kind),
        );
        files.add(
          existingHashes.isEmpty
              ? file
              : file.withExistingStatus(
                  existingHashes.contains(await hashFile(file.path)),
                ),
        );
      }
    }
    final pairs = <String, Map<MediaKind, List<MediaFile>>>{};
    final singles = <ReviewItem>[];
    for (final file in files) {
      if (file.kind == MediaKind.jpeg || file.kind == MediaKind.cr3) {
        final key = '${path.dirname(file.path).toLowerCase()}/${file.stem}';
        pairs
            .putIfAbsent(key, () => {})
            .putIfAbsent(file.kind, () => [])
            .add(file);
      } else {
        singles.add(ReviewItem(single: file));
      }
    }
    return [
      ...pairs.values.expand((files) {
        final jpegs = files[MediaKind.jpeg] ?? [];
        final cr3s = files[MediaKind.cr3] ?? [];
        final count = jpegs.length > cr3s.length ? jpegs.length : cr3s.length;
        return List.generate(
          (count),
          (index) => ReviewItem(
            jpeg: index < jpegs.length ? jpegs[index] : null,
            cr3: index < cr3s.length ? cr3s[index] : null,
          ),
        );
      }),
      ...singles,
    ]..sort((a, b) => a.label.compareTo(b.label));
  }

  Future<List<ReviewItem>> markExisting(
    List<ReviewItem> items,
    Map<int, Set<String>> existingHashesBySize,
  ) async {
    var candidateCount = 0;
    var candidateBytes = 0;
    final marked = <ReviewItem>[];
    for (final item in items) {
      final files = <MediaFile>[];
      for (final file in item.files) {
        final size = (await File(file.path).stat()).size;
        final hashes = existingHashesBySize[size];
        if (hashes != null) candidateCount++;
        if (hashes != null) candidateBytes += size;
        files.add(
          hashes == null
              ? file
              : file.withExistingStatus(
                  hashes.contains(await hashFile(file.path)),
                ),
        );
      }
      marked.add(
        item.isPair
            ? ReviewItem(
                jpeg: files
                    .where((file) => file.kind == MediaKind.jpeg)
                    .firstOrNull,
                cr3: files
                    .where((file) => file.kind == MediaKind.cr3)
                    .firstOrNull,
              )
            : ReviewItem(single: files.single),
      );
    }
    debugPrint(
      '[scan] duplicate candidates: $candidateCount SHA-256 hashes, '
      '${_formatBytes(candidateBytes)} to read',
    );
    return marked;
  }

  Future<Set<String>> scanLibraryHashes(
    String library, {
    Set<int>? candidateSizes,
  }) async {
    final hashes = <String>{};
    await for (final entity in Directory(
      library,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File ||
          path.basename(entity.path).startsWith('._') ||
          _inTrashFolder(entity.path) ||
          path.split(entity.path).contains('.kinesis-staging')) {
        continue;
      }
      if (_extensions.containsKey(path.extension(entity.path).toLowerCase())) {
        if (candidateSizes != null &&
            !candidateSizes.contains((await entity.stat()).size)) {
          continue;
        }
        hashes.add(await hashFile(entity.path));
      }
    }
    return hashes;
  }

  Future<Set<String>> loadLibraryHashes(
    String library, {
    Set<int>? candidateSizes,
  }) {
    final pending = _libraryIndexLoads[library];
    if (pending != null) {
      debugPrint('[scan] destination index load joined: $library');
      return pending;
    }
    return _libraryIndexLoads[library] = _loadLibraryHashes(library)
        .whenComplete(() {
          _libraryIndexLoads.remove(library);
          debugPrint('[scan] destination index load finished: $library');
        });
  }

  Future<Set<String>> _loadLibraryHashes(String library) async {
    debugPrint('[scan] destination index load started: $library');
    final index = _libraryIndexFile(library);
    final totalWatch = Stopwatch()..start();
    if (await index.exists()) {
      debugPrint('[scan] destination index found: ${index.path}');
      try {
        final json =
            jsonDecode(await index.readAsString()) as Map<String, dynamic>;
        final entries = (json['files'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>();
        if (entries != null) {
          debugPrint(
            '[scan] destination index: validating ${entries.length} entries',
          );
          final current = await _libraryFiles(library);
          final byPath = {for (final file in current) file.path: file};
          final hashes = <String>{};
          final hashesBySize = <int, Set<String>>{};
          var valid = entries.length == current.length;
          for (final entry in entries) {
            final file = byPath[entry['path'] as String?];
            if (file == null ||
                file.size != entry['size'] ||
                file.modifiedMilliseconds != entry['modified']) {
              valid = false;
              break;
            }
            final hash = entry['hash'] as String;
            hashes.add(hash);
            hashesBySize.putIfAbsent(entry['size'] as int, () => {}).add(hash);
          }
          if (valid) {
            _libraryHashesBySize[library] = hashesBySize;
            totalWatch.stop();
            debugPrint(
              '[scan] destination index valid: ${current.length} files in '
              '${totalWatch.elapsedMilliseconds}ms',
            );
            return hashes;
          }
          final hashWatch = Stopwatch()..start();
          debugPrint('[scan] destination index stale: rebuilding hashes');
          final refreshed = await _hashLibraryFiles(current);
          hashWatch.stop();
          _libraryHashesBySize[library] = _groupHashesBySize(
            current,
            refreshed,
          );
          await _writeLibraryIndex(library, current, refreshed);
          totalWatch.stop();
          debugPrint(
            '[scan] destination index rebuilt: ${current.length} files, '
            '${hashWatch.elapsedMilliseconds}ms hashing, '
            '${totalWatch.elapsedMilliseconds}ms total',
          );
          return refreshed.values.toSet();
        }
        // Upgrade the original hash-only index on first use.
        final hashes = ((json['hashes'] as List<dynamic>?) ?? [])
            .cast<String>()
            .toSet();
        if (hashes.isNotEmpty) {
          debugPrint('[scan] destination index legacy: upgrading hashes');
          final current = await _libraryFiles(library);
          final hashWatch = Stopwatch()..start();
          final refreshed = await _hashLibraryFiles(current);
          hashWatch.stop();
          _libraryHashesBySize[library] = _groupHashesBySize(
            current,
            refreshed,
          );
          await _writeLibraryIndex(library, current, refreshed);
          totalWatch.stop();
          debugPrint(
            '[scan] destination index upgraded: ${current.length} files, '
            '${hashWatch.elapsedMilliseconds}ms hashing, '
            '${totalWatch.elapsedMilliseconds}ms total',
          );
          return refreshed.values.toSet();
        }
      } on FormatException {
        // Rebuild a damaged index from the library contents.
      }
    }
    // A newly created index must contain the complete library, not only the
    // files that happened to match the current source selection.
    debugPrint('[scan] destination index missing: enumerating library files');
    final files = await _libraryFiles(library);
    final hashWatch = Stopwatch()..start();
    debugPrint(
      '[scan] destination index missing: hashing ${files.length} files',
    );
    final hashes = await _hashLibraryFiles(files);
    hashWatch.stop();
    _libraryHashesBySize[library] = _groupHashesBySize(files, hashes);
    await _writeLibraryIndex(library, files, hashes);
    totalWatch.stop();
    debugPrint(
      '[scan] destination index created: ${files.length} files, '
      '${hashWatch.elapsedMilliseconds}ms hashing, '
      '${totalWatch.elapsedMilliseconds}ms total',
    );
    return hashes.values.toSet();
  }

  Future<Map<int, Set<String>>> libraryHashesBySize(String library) async {
    final index = _libraryIndexFile(library);
    debugPrint('[scan] destination index: checking ${index.path}');
    final refreshWatch = Stopwatch()..start();
    await loadLibraryHashes(library);
    refreshWatch.stop();
    final hashes = _libraryHashesBySize[library] ?? const <int, Set<String>>{};
    debugPrint(
      '[scan] destination index refresh: ${refreshWatch.elapsedMilliseconds}ms, '
      '${hashes.values.fold<int>(0, (total, values) => total + values.length)} '
      'files in ${hashes.length} size groups',
    );
    return {
      for (final entry in hashes.entries)
        entry.key: Set<String>.of(entry.value),
    };
  }

  Map<int, Set<String>> _groupHashesBySize(
    List<_LibraryFile> files,
    Map<String, String> hashesByPath,
  ) {
    final grouped = <int, Set<String>>{};
    for (final file in files) {
      final hash = hashesByPath[file.path];
      if (hash != null) grouped.putIfAbsent(file.size, () => {}).add(hash);
    }
    return grouped;
  }

  Future<void> writeLibraryHashes(
    String library,
    Set<String> hashes, {
    Map<String, String>? pathsByHash,
  }) async {
    final current = await _libraryFiles(library);
    final entries = await _hashLibraryFiles(current);
    await _writeLibraryIndex(library, current, entries);
  }

  Future<void> writeImportedAssetsToLibraryIndex(
    String library,
    Iterable<ImportedAsset> assets,
  ) async {
    final root = path.normalize(path.absolute(library));
    final additions = <String, _LibraryFile>{};
    final addedHashes = <String, String>{};
    for (final asset in assets) {
      final absolutePath = path.normalize(path.absolute(asset.path));
      if (!path.isWithin(root, absolutePath)) continue;
      final stat = await File(absolutePath).stat();
      final relativePath = path.relative(absolutePath, from: root);
      additions[relativePath] = _LibraryFile(
        path: relativePath,
        size: stat.size,
        modifiedMilliseconds: stat.modified.millisecondsSinceEpoch,
        absolutePath: absolutePath,
      );
      addedHashes[relativePath] = asset.hash;
    }
    if (additions.isEmpty) return;

    final filesByPath = <String, _LibraryFile>{};
    final hashesByPath = <String, String>{};
    var indexIsUsable = false;
    final index = _libraryIndexFile(root);
    if (await index.exists()) {
      try {
        final decoded = jsonDecode(await index.readAsString());
        if (decoded is Map<String, dynamic> &&
            decoded['version'] == 2 &&
            decoded['files'] is List<dynamic>) {
          indexIsUsable = true;
          for (final value in decoded['files'] as List<dynamic>) {
            if (value is! Map<String, dynamic> ||
                value['path'] is! String ||
                value['hash'] is! String ||
                value['size'] is! int ||
                value['modified'] is! int) {
              indexIsUsable = false;
              break;
            }
            final relativePath = path.normalize(value['path'] as String);
            final absolutePath = path.normalize(
              path.absolute(path.join(root, relativePath)),
            );
            if (path.isAbsolute(relativePath) ||
                !path.isWithin(root, absolutePath)) {
              indexIsUsable = false;
              break;
            }
            filesByPath[relativePath] = _LibraryFile(
              path: relativePath,
              size: value['size'] as int,
              modifiedMilliseconds: value['modified'] as int,
              absolutePath: absolutePath,
            );
            hashesByPath[relativePath] = value['hash'] as String;
          }
        }
      } on FormatException {
        // Rebuild a damaged index before applying the imported-file updates.
      }
    }

    if (!indexIsUsable) {
      final existingFiles = await _libraryFiles(root);
      filesByPath
        ..clear()
        ..addEntries(existingFiles.map((file) => MapEntry(file.path, file)));
      hashesByPath
        ..clear()
        ..addAll(await _hashLibraryFiles(existingFiles));
    }
    filesByPath.addAll(additions);
    hashesByPath.addAll(addedHashes);
    final files = filesByPath.values.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    await _writeLibraryIndex(root, files, hashesByPath);
    _libraryHashesBySize[library] = _groupHashesBySize(files, hashesByPath);
  }

  Future<void> _writeLibraryIndex(
    String library,
    List<_LibraryFile> files,
    Map<String, String> hashes,
  ) async {
    final index = _libraryIndexFile(library);
    final temporary = File(
      '${index.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    final contents = jsonEncode({
      'version': 2,
      'files': [
        for (final file in files)
          if (hashes.containsKey(file.path))
            {
              'path': file.path,
              'hash': hashes[file.path],
              'size': file.size,
              'modified': file.modifiedMilliseconds,
            },
      ],
    });
    try {
      await index.parent.create(recursive: true);
      await temporary.writeAsString(contents, flush: true);
      try {
        await temporary.rename(index.path);
      } on FileSystemException {
        // SMB/NAS volumes often refuse to rename over an existing file
        // (EBUSY). Remove the old index and retry, then fall back to writing
        // in place. The index is only a cache, so failure must not stop scan.
        try {
          if (await index.exists()) await index.delete();
          await temporary.rename(index.path);
        } on FileSystemException {
          try {
            await index.writeAsString(contents, flush: true);
          } on FileSystemException catch (fallbackError) {
            debugPrint('[scan] index write failed: $fallbackError');
          }
        }
      }
    } on FileSystemException catch (error) {
      debugPrint('[scan] index cache write failed: $error');
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // A leftover temporary cache file is harmless and ignored by scans.
      }
    }
  }

  File _libraryIndexFile(String library) =>
      File(path.join(library, '.kinesis', 'index.json'));

  /// Lists JPEG files under [root] without reading EXIF. Used to match a RAW
  /// on a source card with a JPEG that was already imported into the library.
  Future<List<MediaFile>> listJpegs(String root) async {
    if (!await Directory(root).exists()) return const [];
    final files = await _libraryFiles(root);
    return [
      for (final file in files)
        if (_isJpegPath(file.absolutePath))
          MediaFile(
            path: file.absolutePath,
            kind: MediaKind.jpeg,
            sizeBytes: file.size,
          ),
    ];
  }

  /// JPEGs in the destination index, keyed by lowercase shot name. Reading the
  /// index avoids walking slow removable or network volumes again during a
  /// source scan; falls back to [listJpegs] when no index is available.
  Future<Map<String, MediaFile>> libraryJpegs(String root) async {
    final index = _libraryIndexFile(root);
    try {
      if (await index.exists()) {
        final decoded = jsonDecode(await index.readAsString());
        if (decoded is Map<String, dynamic> &&
            decoded['version'] == 2 &&
            decoded['files'] is List<dynamic>) {
          final jpegs = <String, MediaFile>{};
          for (final value in decoded['files'] as List<dynamic>) {
            if (value is! Map<String, dynamic>) continue;
            final relative = value['path'];
            final size = value['size'];
            if (relative is! String || size is! int) continue;
            if (!_isJpegPath(relative)) continue;
            final absolute = path.normalize(path.join(root, relative));
            final stem = path.basenameWithoutExtension(absolute).toLowerCase();
            jpegs.putIfAbsent(
              stem,
              () => MediaFile(
                path: absolute,
                kind: MediaKind.jpeg,
                sizeBytes: size,
              ),
            );
          }
          return jpegs;
        }
      }
    } on Object catch (error) {
      debugPrint('[scan] destination JPEG index read failed: $error');
    }
    return {for (final jpeg in await listJpegs(root)) jpeg.stem: jpeg};
  }

  static bool _isJpegPath(String filePath) {
    final extension = path.extension(filePath).toLowerCase();
    return extension == '.jpg' || extension == '.jpeg';
  }

  Future<List<MediaFile>> listLibraryMedia(String library) async {
    final files = await _libraryFiles(library);
    files.sort((a, b) => a.path.compareTo(b.path));
    final result = List<MediaFile?>.filled(files.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < files.length) {
        final i = next++;
        final file = files[i];
        final kind = _extensions[path.extension(file.path).toLowerCase()]!;
        result[i] = MediaFile(
          path: file.absolutePath,
          kind: kind,
          sizeBytes: file.size,
          captureDate: await _readCaptureDate(File(file.absolutePath), kind),
        );
      }
    }

    await Future.wait([for (var w = 0; w < 6; w++) worker()]);
    return result.cast<MediaFile>();
  }

  Future<List<_LibraryFile>> _libraryFiles(String library) async {
    final files = <_LibraryFile>[];
    await for (final entity in Directory(
      library,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File ||
          path.basename(entity.path).startsWith('._') ||
          _inTrashFolder(entity.path) ||
          path.split(entity.path).contains('.kinesis-staging')) {
        continue;
      }
      if (!_extensions.containsKey(path.extension(entity.path).toLowerCase())) {
        continue;
      }
      final stat = await entity.stat();
      files.add(
        _LibraryFile(
          path: path.relative(entity.path, from: library),
          size: stat.size,
          modifiedMilliseconds: stat.modified.millisecondsSinceEpoch,
          absolutePath: entity.path,
        ),
      );
    }
    return files;
  }

  Future<Map<String, String>> _hashLibraryFiles(
    List<_LibraryFile> files,
  ) async => {
    for (final file in files) file.path: await hashFile(file.absolutePath),
  };

  Future<String> hashFile(String filePath) async {
    final digest = await sha256.bind(File(filePath).openRead()).first;
    return digest.toString();
  }

  String _formatBytes(int bytes) {
    const megabyte = 1024 * 1024;
    const gigabyte = 1024 * megabyte;
    if (bytes >= gigabyte) return '${(bytes / gigabyte).toStringAsFixed(1)} GB';
    return '${(bytes / megabyte).toStringAsFixed(1)} MB';
  }

  Future<ImportedAsset> copyAndVerify(
    MediaFile source,
    String library,
    String template,
  ) async {
    final date = (await File(source.path).stat()).modified;
    final directory = expandTemplate(
      template,
      date,
      source.name,
      path.basename(path.dirname(source.path)),
    );
    final libraryRoot = path.normalize(path.absolute(library));
    final destinationPath = path.normalize(
      path.absolute(path.join(libraryRoot, directory)),
    );
    if (path.isAbsolute(directory) ||
        !path.isWithin(libraryRoot, destinationPath)) {
      throw FileSystemException(
        'Destination template must remain inside the library',
        template,
      );
    }
    final destinationDirectory = Directory(destinationPath);
    await destinationDirectory.create(recursive: true);
    final staging = Directory(path.join(library, '.kinesis-staging'));
    await staging.create(recursive: true);
    final sourceHash = source.hash ?? await hashFile(source.path);
    var destination = File(path.join(destinationDirectory.path, source.name));
    var number = 1;
    while (await destination.exists()) {
      final base = path.basenameWithoutExtension(source.name);
      destination = File(
        path.join(
          destinationDirectory.path,
          '$base ($number)${path.extension(source.name)}',
        ),
      );
      number++;
    }
    final staged = File(
      path.join(
        staging.path,
        '${DateTime.now().microsecondsSinceEpoch}-${source.name}',
      ),
    );
    await File(source.path).copy(staged.path);
    if (await hashFile(staged.path) != sourceHash) {
      await staged.delete();
      throw FileSystemException('Copied bytes did not verify', source.path);
    }
    await staged.rename(destination.path);
    return ImportedAsset(
      hash: sourceHash,
      path: destination.path,
      kind: source.kind,
    );
  }

  String expandTemplate(
    String template,
    DateTime date,
    String name,
    String sourceFolder,
  ) => template
      .replaceAll('{year}', date.year.toString())
      .replaceAll('{month}', date.month.toString().padLeft(2, '0'))
      .replaceAll('{day}', date.day.toString().padLeft(2, '0'))
      .replaceAll('{originalName}', name)
      .replaceAll('{sourceFolder}', sourceFolder);
}

/// Runs in a worker isolate. JPEG EXIF lives in the first few dozen KB, so only
/// the head of the file is read instead of the whole image.
Future<String?> _readExifDateString(String filePath, bool headOnly) async {
  final Map<String, IfdTag> tags;
  if (headOnly) {
    final raf = await File(filePath).open();
    try {
      final bytes = await raf.read(256 * 1024);
      tags = await readExifFromBytes(bytes);
    } finally {
      await raf.close();
    }
  } else {
    tags = await readExifFromFile(File(filePath));
  }
  for (final name in const [
    'EXIF DateTimeOriginal',
    'EXIF DateTimeDigitized',
    'Image DateTime',
  ]) {
    final value = tags[name]?.printable;
    if (value != null) return value;
  }
  return null;
}

class _LibraryFile {
  const _LibraryFile({
    required this.path,
    required this.size,
    required this.modifiedMilliseconds,
    required this.absolutePath,
  });

  final String path;
  final int size;
  final int modifiedMilliseconds;
  final String absolutePath;
}

class ImportedAsset {
  const ImportedAsset({
    required this.hash,
    required this.path,
    required this.kind,
  });

  final String hash;
  final String path;
  final MediaKind kind;

  Map<String, String> toJson() => {
    'hash': hash,
    'path': path,
    'kind': kind.name,
  };

  static ImportedAsset fromJson(Map<String, dynamic> json) => ImportedAsset(
    hash: json['hash']! as String,
    path: json['path']! as String,
    kind: MediaKind.values.byName(json['kind']! as String),
  );
}

class LocalStore {
  LocalStore(this.file);
  final File file;

  Future<Map<String, dynamic>> read() async {
    if (!await file.exists()) return {};
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<void> write(Map<String, dynamic> value) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(file.path);
  }
}

bool _inTrashFolder(String filePath) =>
    path.split(filePath).contains('.kinesis-trash');

class TrashService {
  static const _channel = MethodChannel('com.maxsloof.kinesis/trash');

  /// Moves [filePath] to the system Trash. Volumes without a Trash (NAS/SMB
  /// shares) fall back to a `.kinesis-trash/<date>/` holding folder at the
  /// volume root, preserving the relative path so nothing collides.
  Future<void> moveToTrash(String filePath) async {
    try {
      await _systemTrash(filePath);
    } on Object catch (error) {
      debugPrint(
        '[trash] system Trash unavailable, using holding folder: $error',
      );
      await _moveToHoldingFolder(filePath);
    }
  }

  Future<void> _moveToHoldingFolder(String filePath) async {
    final absolute = path.normalize(path.absolute(filePath));
    final root = _volumeRoot(absolute);
    final now = DateTime.now();
    final stamp =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    var target = path.join(
      root,
      '.kinesis-trash',
      stamp,
      path.relative(absolute, from: root),
    );
    await Directory(path.dirname(target)).create(recursive: true);
    if (await File(target).exists()) {
      target =
          '${path.withoutExtension(target)}-${now.microsecondsSinceEpoch}'
          '${path.extension(target)}';
    }
    await File(absolute).rename(target);
  }

  String _volumeRoot(String absolute) {
    final parts = path.split(absolute);
    // macOS mounts external and network volumes at /Volumes/<name>,
    // Linux at /media/<user>/<name> or /mnt/<name>.
    if (parts.length > 3 && parts[1] == 'Volumes') {
      return path.joinAll(parts.take(3));
    }
    if (parts.length > 4 && parts[1] == 'media') {
      return path.joinAll(parts.take(4));
    }
    if (parts.length > 3 && parts[1] == 'mnt') {
      return path.joinAll(parts.take(3));
    }
    return path.dirname(absolute);
  }

  Future<void> _systemTrash(String filePath) async {
    if (Platform.isLinux) {
      final result = await Process.run('gio', ['trash', filePath]);
      if (result.exitCode != 0) {
        throw FileSystemException(
          'Could not move file to Trash: ${result.stderr}',
          filePath,
        );
      }
      return;
    }
    await _channel.invokeMethod<void>('moveToTrash', {'path': filePath});
  }
}
