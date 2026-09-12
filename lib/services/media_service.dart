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

  Future<List<ReviewItem>> scan(String source) async {
    final files = <MediaFile>[];
    await for (final entity in Directory(
      source,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final kind = _extensions[path.extension(entity.path).toLowerCase()];
      if (kind != null) files.add(MediaFile(path: entity.path, kind: kind));
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

  Future<void> moveToTrash(String filePath) =>
      _channel.invokeMethod<void>('moveToTrash', {'path': filePath});
}
