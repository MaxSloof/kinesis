import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../domain/media.dart';

class MediaService {
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
      final kind = _extensions[path.extension(entity.path).toLowerCase()];
      if (kind != null) {
        final file = MediaFile(path: entity.path, kind: kind);
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
    Set<String> existingHashes,
  ) async {
    final marked = <ReviewItem>[];
    for (final item in items) {
      final files = <MediaFile>[];
      for (final file in item.files) {
        final hash = await hashFile(file.path);
        files.add(file.withExistingStatus(existingHashes.contains(hash)));
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
      if (entity is! File || path.basename(entity.path).startsWith('._')) {
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
  }) async {
    final index = _libraryIndexFile(library);
    if (await index.exists()) {
      try {
        final json =
            jsonDecode(await index.readAsString()) as Map<String, dynamic>;
        final entries = (json['files'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>();
        if (entries != null) {
          final current = await _libraryFiles(library);
          final byPath = {for (final file in current) file.path: file};
          final hashes = <String>{};
          var valid = entries.length == current.length;
          for (final entry in entries) {
            final file = byPath[entry['path'] as String?];
            if (file == null ||
                file.size != entry['size'] ||
                file.modifiedMilliseconds != entry['modified']) {
              valid = false;
              break;
            }
            hashes.add(entry['hash'] as String);
          }
          if (valid) return hashes;
          final refreshed = await _hashLibraryFiles(current);
          await _writeLibraryIndex(library, current, refreshed);
          return refreshed.values.toSet();
        }
        // Upgrade the original hash-only index on first use.
        final hashes = ((json['hashes'] as List<dynamic>?) ?? [])
            .cast<String>()
            .toSet();
        if (hashes.isNotEmpty) {
          final current = await _libraryFiles(library);
          final refreshed = await _hashLibraryFiles(current);
          await _writeLibraryIndex(library, current, refreshed);
          return refreshed.values.toSet();
        }
      } on FormatException {
        // Rebuild a damaged index from the library contents.
      }
    }
    // A newly created index must contain the complete library, not only the
    // files that happened to match the current source selection.
    final hashes = await _hashLibraryFiles(await _libraryFiles(library));
    await _writeLibraryIndex(library, await _libraryFiles(library), hashes);
    return hashes.values.toSet();
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

  Future<void> _writeLibraryIndex(
    String library,
    List<_LibraryFile> files,
    Map<String, String> hashes,
  ) async {
    final index = _libraryIndexFile(library);
    await index.parent.create(recursive: true);
    final temporary = File('${index.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
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
      }),
      flush: true,
    );
    await temporary.rename(index.path);
  }

  File _libraryIndexFile(String library) =>
      File(path.join(library, '.kinesis', 'index.json'));

  Future<List<_LibraryFile>> _libraryFiles(String library) async {
    final files = <_LibraryFile>[];
    await for (final entity in Directory(
      library,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File || path.basename(entity.path).startsWith('._')) {
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

class TrashService {
  static const _channel = MethodChannel('com.maxsloof.kinesis/trash');

  Future<void> moveToTrash(String filePath) async {
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
