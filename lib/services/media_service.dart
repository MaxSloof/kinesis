import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../domain/capture_date.dart';
import '../domain/media.dart';
import 'cr3_metadata.dart';
import 'saf_storage.dart';

class MediaService {
  MediaService({Future<String> Function(String path)? localHasher})
    : _localHasher = localHasher ?? _sha256InIsolate;

  /// Index file format. Version 2 (every entry hashed) is still read; version 3
  /// makes `hash` optional so files are only hashed when a size collides with
  /// a source file.
  static const _indexVersion = 3;
  static const _hashConcurrency = 3;
  static final _libraryIndexLoads = <String, Future<Set<String>>>{};
  static final _hashesBySizeByLoad = <String, Map<int, Set<String>>>{};
  static final _safIndexes = <String, Map<String, _LibraryFile>>{};
  static final _hashSlots = _Semaphore(_hashConcurrency);

  final Future<String> Function(String path) _localHasher;

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

  Future<DateTime?> _readCaptureDate(String filePath, MediaKind kind) async {
    if (kind == MediaKind.video) return null;
    try {
      final isSaf = SafStorage.isUri(filePath);
      if (kind == MediaKind.cr3) {
        return isSaf
            ? cr3CaptureDateFromHead(
                await SafStorage.instance.readHead(filePath, 1024 * 1024),
              )
            : await Isolate.run(() => readCr3CaptureDate(filePath));
      }
      final value = isSaf
          ? await _readSafExifDateString(filePath)
          : await Isolate.run(
              () => _readExifDateString(filePath, kind == MediaKind.jpeg),
            );
      return value == null ? null : parseExifDate(value);
    } on Object catch (error) {
      debugPrint(
        '[metadata] could not read capture date for $filePath: $error',
      );
    }
    return null;
  }

  Future<List<ReviewItem>> scan(
    String source, {
    Set<String> existingHashes = const {},
  }) async {
    final files = <MediaFile>[];
    if (SafStorage.isUri(source)) {
      final sourceRootName = (await SafStorage.instance.stat(source))?.name;
      await for (final entry in SafStorage.instance.walk(source)) {
        final document = entry.file;
        if (document.isDir || document.name.startsWith('._')) continue;
        if (entry.relativePath.split('/').contains('.kinesis-trash')) continue;
        final kind = _extensions[path.extension(document.name).toLowerCase()];
        if (kind == null) continue;
        final file = MediaFile(
          path: document.uri,
          kind: kind,
          displayName: document.name,
          relativePath: entry.relativePath,
          rootUri: source,
          rootName: sourceRootName,
          sizeBytes: document.length,
          modified: DateTime.fromMillisecondsSinceEpoch(document.lastModified),
          captureDate: await _readCaptureDate(document.uri, kind),
        );
        files.add(
          existingHashes.isEmpty
              ? file
              : file.withExistingStatus(
                  existingHashes.contains(await hashFile(file.path)),
                ),
        );
      }
    } else {
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
            modified: stat.modified,
            captureDate: await _readCaptureDate(entity.path, kind),
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
    }
    final pairs = <String, Map<MediaKind, List<MediaFile>>>{};
    final singles = <ReviewItem>[];
    for (final file in files) {
      if (file.kind == MediaKind.jpeg || file.kind == MediaKind.cr3) {
        final key = file.pairingKey.toLowerCase();
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

  Future<int> _sizeOf(MediaFile file) async =>
      file.sizeBytes ??
      (SafStorage.isUri(file.path)
          ? (await SafStorage.instance.stat(file.path))?.length ?? 0
          : (await File(file.path).stat()).size);

  /// Sizes of all source files. Only library files of these sizes can be
  /// duplicates, so only those need hashes.
  Future<Set<int>> sourceSizes(List<ReviewItem> items) async => {
    for (final item in items)
      for (final file in item.files) await _sizeOf(file),
  };

  Future<List<ReviewItem>> markExisting(
    List<ReviewItem> items,
    Map<int, Set<String>> existingHashesBySize,
  ) async {
    var candidateCount = 0;
    var candidateBytes = 0;
    final marked = <ReviewItem>[];
    for (final item in items) {
      final sizes = [for (final file in item.files) await _sizeOf(file)];
      final hashes = await Future.wait([
        for (var i = 0; i < sizes.length; i++)
          if (existingHashesBySize.containsKey(sizes[i]))
            hashFile(item.files[i].path)
          else
            Future<String?>.value(),
      ]);
      final files = <MediaFile>[];
      for (var i = 0; i < sizes.length; i++) {
        final file = item.files[i];
        final candidates = existingHashesBySize[sizes[i]];
        if (candidates == null) {
          files.add(file);
          continue;
        }
        candidateCount++;
        candidateBytes += sizes[i];
        files.add(file.withExistingStatus(candidates.contains(hashes[i])));
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
    if (SafStorage.isUri(library)) {
      for (final file in await _libraryFiles(library)) {
        if (candidateSizes != null && !candidateSizes.contains(file.size)) {
          continue;
        }
        hashes.add(await hashFile(file.absolutePath));
      }
      return hashes;
    }
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
    final key = _loadKey(library, candidateSizes);
    final pending = _libraryIndexLoads[key];
    if (pending != null) {
      debugPrint('[scan] destination index load joined: $library');
      return pending;
    }
    return _libraryIndexLoads[key] =
        _loadLibraryHashes(library, candidateSizes, key).whenComplete(() {
          _libraryIndexLoads.remove(key);
          debugPrint('[scan] destination index load finished: $library');
        });
  }

  static String _loadKey(String library, Set<int>? candidateSizes) =>
      '$library\u0000'
      '${candidateSizes == null ? '*' : (candidateSizes.toList()..sort()).join(',')}';

  Future<Set<String>> _loadLibraryHashes(
    String library,
    Set<int>? candidateSizes,
    String key,
  ) async {
    final files = await _refreshLibraryIndex(library, candidateSizes);
    final grouped = <int, Set<String>>{};
    final hashes = <String>{};
    for (final file in files) {
      final hash = file.hash;
      if (hash == null ||
          (candidateSizes != null && !candidateSizes.contains(file.size))) {
        continue;
      }
      hashes.add(hash);
      grouped.putIfAbsent(file.size, () => {}).add(hash);
    }
    _hashesBySizeByLoad[key] = grouped;
    return hashes;
  }

  /// Brings the library index in line with the files on disk. Stored hashes
  /// are reused only while path, size and modified time still match, and only
  /// files whose size is in [candidateSizes] (all files when null) are hashed.
  Future<List<_LibraryFile>> _refreshLibraryIndex(
    String library,
    Set<int>? candidateSizes,
  ) async {
    final totalWatch = Stopwatch()..start();
    final isSaf = SafStorage.isUri(library);
    final current = await _libraryFiles(library);
    final stored = isSaf ? null : await _readLibraryIndex(library);
    final known = isSaf ? _safIndexes[library] : stored?.files;
    var dirty = !isSaf && (stored == null || stored.version != _indexVersion);
    if (known == null || known.length != current.length) dirty = true;
    final merged = <_LibraryFile>[];
    for (final file in current) {
      final previous = known?[file.path];
      if (previous != null &&
          previous.size == file.size &&
          previous.modifiedMilliseconds == file.modifiedMilliseconds) {
        merged.add(
          previous.hash == null ? file : file.withHash(previous.hash!),
        );
      } else {
        merged.add(file);
        dirty = true;
      }
    }
    final pending = [
      for (var index = 0; index < merged.length; index++)
        if (merged[index].hash == null &&
            (candidateSizes == null ||
                candidateSizes.contains(merged[index].size)))
          index,
    ];
    final hashWatch = Stopwatch()..start();
    final hashes = await Future.wait([
      for (final index in pending) hashFile(merged[index].absolutePath),
    ]);
    hashWatch.stop();
    for (var i = 0; i < pending.length; i++) {
      merged[pending[i]] = merged[pending[i]].withHash(hashes[i]);
    }
    if (pending.isNotEmpty) dirty = true;
    if (isSaf) {
      _safIndexes[library] = {for (final file in merged) file.path: file};
    } else if (dirty) {
      await _writeLibraryIndex(library, merged);
    }
    totalWatch.stop();
    debugPrint(
      '[scan] destination index: ${merged.length} files, ${pending.length} '
      'hashed in ${hashWatch.elapsedMilliseconds}ms, '
      '${totalWatch.elapsedMilliseconds}ms total',
    );
    return merged;
  }

  /// Reads `.kinesis/index.json`. A missing, corrupt or unknown-version index
  /// is treated as absent, so the caller rebuilds it from the library files.
  Future<_StoredIndex?> _readLibraryIndex(String library) async {
    final index = _libraryIndexFile(library);
    try {
      if (!await index.exists()) return null;
      final decoded = jsonDecode(await index.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final version = decoded['version'];
      final entries = decoded['files'];
      if ((version != 2 && version != _indexVersion) || entries is! List) {
        return null;
      }
      final root = path.normalize(path.absolute(library));
      final files = <String, _LibraryFile>{};
      for (final value in entries) {
        if (value is! Map<String, dynamic> ||
            value['path'] is! String ||
            value['size'] is! int ||
            value['modified'] is! int ||
            (value['hash'] != null && value['hash'] is! String) ||
            (version == 2 && value['hash'] == null)) {
          return null;
        }
        final relativePath = path.normalize(value['path'] as String);
        final absolutePath = path.normalize(path.join(root, relativePath));
        if (path.isAbsolute(relativePath) ||
            !path.isWithin(root, absolutePath)) {
          return null;
        }
        files[relativePath] = _LibraryFile(
          path: relativePath,
          size: value['size'] as int,
          modifiedMilliseconds: value['modified'] as int,
          absolutePath: absolutePath,
          name: path.basename(absolutePath),
          hash: value['hash'] as String?,
        );
      }
      return _StoredIndex(version as int, files);
    } on Object catch (error) {
      debugPrint('[scan] destination index unreadable, rebuilding: $error');
      return null;
    }
  }

  Future<Map<int, Set<String>>> libraryHashesBySize(
    String library, {
    Set<int>? candidateSizes,
  }) async {
    final refreshWatch = Stopwatch()..start();
    await loadLibraryHashes(library, candidateSizes: candidateSizes);
    refreshWatch.stop();
    final hashes =
        _hashesBySizeByLoad[_loadKey(library, candidateSizes)] ??
        const <int, Set<String>>{};
    debugPrint(
      '[scan] destination index refresh: ${refreshWatch.elapsedMilliseconds}ms, '
      '${hashes.values.fold<int>(0, (total, values) => total + values.length)} '
      'hashes in ${hashes.length} size groups',
    );
    return {
      for (final entry in hashes.entries)
        entry.key: Set<String>.of(entry.value),
    };
  }

  Future<void> writeLibraryHashes(
    String library,
    Set<String> hashes, {
    Map<String, String>? pathsByHash,
  }) async {
    await loadLibraryHashes(library);
  }

  Future<void> writeImportedAssetsToLibraryIndex(
    String library,
    Iterable<ImportedAsset> assets,
  ) async {
    // SAF libraries have no on-disk index; hashes are re-read lazily.
    if (SafStorage.isUri(library)) return;
    final root = path.normalize(path.absolute(library));
    final additions = <String, _LibraryFile>{};
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
        name: path.basename(absolutePath),
        hash: asset.hash,
      );
    }
    if (additions.isEmpty) return;

    final stored = await _readLibraryIndex(root);
    final filesByPath = <String, _LibraryFile>{
      if (stored != null)
        ...stored.files
      else
        for (final file in await _libraryFiles(root)) file.path: file,
      ...additions,
    };
    final files = filesByPath.values.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    await _writeLibraryIndex(root, files);
  }

  Future<void> _writeLibraryIndex(
    String library,
    List<_LibraryFile> files,
  ) async {
    final index = _libraryIndexFile(library);
    final temporary = File(
      '${index.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    final contents = jsonEncode({
      'version': _indexVersion,
      'files': [
        for (final file in files)
          {
            'path': file.path,
            if (file.hash != null) 'hash': file.hash,
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
    if (SafStorage.isUri(root)) {
      return [
        for (final file in await _libraryFiles(root))
          if (_isJpegPath(file.path))
            MediaFile(
              path: file.absolutePath,
              kind: MediaKind.jpeg,
              displayName: file.name,
              relativePath: file.path,
              rootUri: root,
              sizeBytes: file.size,
              modified: DateTime.fromMillisecondsSinceEpoch(
                file.modifiedMilliseconds,
              ),
            ),
      ];
    }
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
    if (SafStorage.isUri(root)) {
      return {for (final jpeg in await listJpegs(root)) jpeg.stem: jpeg};
    }
    final index = _libraryIndexFile(root);
    try {
      if (await index.exists()) {
        final decoded = jsonDecode(await index.readAsString());
        if (decoded is Map<String, dynamic> &&
            (decoded['version'] == 2 || decoded['version'] == 3) &&
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
          displayName: file.name,
          relativePath: file.path,
          rootUri: SafStorage.isUri(library) ? library : null,
          sizeBytes: file.size,
          modified: DateTime.fromMillisecondsSinceEpoch(
            file.modifiedMilliseconds,
          ),
          captureDate: await _readCaptureDate(file.absolutePath, kind),
        );
      }
    }

    await Future.wait([for (var w = 0; w < 6; w++) worker()]);
    return result.cast<MediaFile>();
  }

  Future<List<_LibraryFile>> _libraryFiles(String library) async {
    final files = <_LibraryFile>[];
    if (SafStorage.isUri(library)) {
      await for (final entry in SafStorage.instance.walk(library)) {
        final document = entry.file;
        if (document.isDir ||
            document.name.startsWith('._') ||
            entry.relativePath.split('/').contains('.kinesis-trash') ||
            entry.relativePath.split('/').contains('.kinesis-staging')) {
          continue;
        }
        if (!_extensions.containsKey(
          path.extension(document.name).toLowerCase(),
        )) {
          continue;
        }
        files.add(
          _LibraryFile(
            path: entry.relativePath,
            size: document.length,
            modifiedMilliseconds: document.lastModified,
            absolutePath: document.uri,
            name: document.name,
          ),
        );
      }
      return files;
    }
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
          name: path.basename(entity.path),
        ),
      );
    }
    return files;
  }

  /// The single entry point for SHA-256 of a file. Local files are hashed in
  /// worker isolates, a few at a time, so the UI isolate stays responsive.
  Future<String> hashFile(String filePath) async {
    if (SafStorage.isUri(filePath)) {
      return SafStorage.instance.hashFile(filePath);
    }
    await _hashSlots.acquire();
    try {
      return await _localHasher(filePath);
    } finally {
      _hashSlots.release();
    }
  }

  String _formatBytes(int bytes) {
    const megabyte = 1024 * 1024;
    const gigabyte = 1024 * megabyte;
    if (bytes >= gigabyte) return '${(bytes / gigabyte).toStringAsFixed(1)} GB';
    return '${(bytes / megabyte).toStringAsFixed(1)} MB';
  }

  /// The date used for the destination folder. Pass the review item's
  /// [captureDate] so a JPEG and its CR3 share one folder.
  Future<DateTime> _destinationDate(
    MediaFile source,
    DateTime? captureDate,
    CaptureDateAdjustment adjustment,
  ) async {
    if (captureDate != null) return captureDate;
    final modified =
        source.modified ??
        (SafStorage.isUri(source.path)
            ? null
            : (await File(source.path).stat()).modified);
    return resolveCaptureDate(
          embedded: source.captureDate,
          fileNames: [source.name],
          modified: modified,
          adjustment: adjustment,
        ) ??
        DateTime.now();
  }

  Future<ImportedAsset> copyAndVerify(
    MediaFile source,
    String library,
    String template, {
    DateTime? captureDate,
    CaptureDateAdjustment adjustment = CaptureDateAdjustment.none,
  }) async {
    if (SafStorage.isUri(library)) {
      return _copyAndVerifySaf(
        source,
        library,
        template,
        captureDate,
        adjustment,
      );
    }
    final date = await _destinationDate(source, captureDate, adjustment);
    final directory = expandTemplate(
      template,
      date,
      source.name,
      _sourceFolder(source),
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
      sizeBytes: source.sizeBytes,
    );
  }

  Future<ImportedAsset> _copyAndVerifySaf(
    MediaFile source,
    String library,
    String template,
    DateTime? captureDate,
    CaptureDateAdjustment adjustment,
  ) async {
    final date = await _destinationDate(source, captureDate, adjustment);
    final directory = expandTemplate(
      template,
      date,
      source.name,
      _sourceFolder(source),
    );
    final segments = path.posix
        .split(directory)
        .where((segment) => segment.isNotEmpty && segment != '.');
    if (path.posix.isAbsolute(directory) ||
        segments.any((part) => part == '..')) {
      throw FileSystemException(
        'Destination template must remain inside the library',
        template,
      );
    }
    final destinationDirectory = segments.isEmpty
        ? await SafStorage.instance.stat(library)
        : await SafStorage.instance.mkdirp(library, segments.toList());
    if (destinationDirectory == null) {
      throw FileSystemException('Could not open SAF destination', library);
    }
    final sourceHash = source.hash ?? await hashFile(source.path);
    final existing = await SafStorage.instance.list(destinationDirectory.uri);
    final occupiedNames = existing.map((entry) => entry.name).toSet();
    var name = source.name;
    var number = 1;
    while (occupiedNames.contains(name)) {
      final base = path.basenameWithoutExtension(source.name);
      name = '$base ($number)${path.extension(source.name)}';
      number++;
    }
    final mimeType = _mimeTypeFor(source.name);
    final copied = await SafStorage.instance.copyVerified(
      sourceUri: source.path,
      destinationDirectoryUri: destinationDirectory.uri,
      name: name,
      mimeType: mimeType,
      expectedHash: sourceHash,
    );
    return ImportedAsset(
      hash: sourceHash,
      path: copied.uri,
      kind: source.kind,
      sizeBytes: copied.length,
      displayName: copied.name,
      relativePath: source.relativePath == null
          ? copied.name
          : path.posix.join(directory, copied.name),
    );
  }

  String _sourceFolder(MediaFile file) {
    final relativePath = file.relativePath;
    if (relativePath != null) {
      final parent = path.posix.dirname(relativePath);
      return parent == '.' ? file.rootName ?? '' : path.posix.basename(parent);
    }
    return path.basename(path.dirname(file.path));
  }

  String _mimeTypeFor(String name) =>
      switch (path.extension(name).toLowerCase()) {
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.cr3' => 'image/x-canon-cr3',
        '.png' => 'image/png',
        '.heic' => 'image/heic',
        '.gif' => 'image/gif',
        '.mp4' => 'video/mp4',
        '.mov' => 'video/quicktime',
        _ => 'application/octet-stream',
      };

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

Future<String?> _readSafExifDateString(String uri) async {
  final bytes = await SafStorage.instance.readHead(uri, 256 * 1024);
  final tags = await readExifFromBytes(bytes);
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
    required this.name,
    this.hash,
  });

  final String path;
  final int size;
  final int modifiedMilliseconds;
  final String absolutePath;
  final String name;
  final String? hash;

  _LibraryFile withHash(String value) => _LibraryFile(
    path: path,
    size: size,
    modifiedMilliseconds: modifiedMilliseconds,
    absolutePath: absolutePath,
    name: name,
    hash: value,
  );
}

class _StoredIndex {
  const _StoredIndex(this.version, this.files);
  final int version;
  final Map<String, _LibraryFile> files;
}

class _Semaphore {
  _Semaphore(this._available);
  int _available;
  final _waiting = <Completer<void>>[];

  Future<void> acquire() {
    if (_available > 0) {
      _available--;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    return waiter.future;
  }

  void release() {
    if (_waiting.isEmpty) {
      _available++;
    } else {
      _waiting.removeAt(0).complete();
    }
  }
}

Future<String> _sha256InIsolate(String filePath) => Isolate.run(() async {
  final digest = await sha256.bind(File(filePath).openRead()).first;
  return digest.toString();
});

class ImportedAsset {
  const ImportedAsset({
    required this.hash,
    required this.path,
    required this.kind,
    this.sizeBytes,
    this.displayName,
    this.relativePath,
  });

  final String hash;
  final String path;
  final MediaKind kind;
  final int? sizeBytes;
  final String? displayName;
  final String? relativePath;

  Map<String, dynamic> toJson() => {
    'hash': hash,
    'path': path,
    'kind': kind.name,
    if (sizeBytes != null) 'sizeBytes': sizeBytes,
    if (displayName != null) 'displayName': displayName,
    if (relativePath != null) 'relativePath': relativePath,
  };

  static ImportedAsset fromJson(Map<String, dynamic> json) => ImportedAsset(
    hash: json['hash']! as String,
    path: json['path']! as String,
    kind: MediaKind.values.byName(json['kind']! as String),
    sizeBytes: json['sizeBytes'] as int?,
    displayName: json['displayName'] as String?,
    relativePath: json['relativePath'] as String?,
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
  Future<void> moveToTrash(MediaFile file) async {
    final filePath = file.path;
    if (SafStorage.isUri(filePath)) {
      final rootUri = file.rootUri;
      final relativePath = file.relativePath;
      if (rootUri == null || relativePath == null) {
        throw FileSystemException('Missing SAF source location', filePath);
      }
      if (await SafStorage.instance.exists(filePath)) {
        await SafStorage.instance.moveToTrash(
          rootUri: rootUri,
          fileUri: filePath,
          relativePath: relativePath,
        );
      }
      return;
    }
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
