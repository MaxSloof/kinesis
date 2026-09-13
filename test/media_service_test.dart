import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/domain/media.dart';
import 'package:kinesis/services/media_service.dart';

void main() {
  test('scan ignores AppleDouble files masquerading as JPEGs', () async {
    final source = await Directory.systemTemp.createTemp('kinesis-scan-');
    addTearDown(() => source.delete(recursive: true));
    await File('${source.path}/._IMG_0001.JPG').writeAsBytes([0, 5, 22, 7]);
    await File('${source.path}/IMG_0001.JPG').writeAsBytes([0xff, 0xd8, 0xff]);

    final items = await MediaService().scan(source.path);

    expect(items, hasLength(1));
    expect(items.single.jpeg!.name, 'IMG_0001.JPG');
  });

  test('scanLibraryHashes finds existing media recursively', () async {
    final library = await Directory.systemTemp.createTemp('kinesis-library-');
    addTearDown(() => library.delete(recursive: true));
    final existing = File('${library.path}/2026/IMG_0001.JPG');
    await existing.create(recursive: true);
    await existing.writeAsBytes([1, 2, 3]);

    final service = MediaService();
    final hashes = await service.scanLibraryHashes(library.path);

    expect(hashes, contains(await service.hashFile(existing.path)));
  });

  test('library SHA index refreshes when a file changes', () async {
    final library = await Directory.systemTemp.createTemp('kinesis-index-');
    addTearDown(() => library.delete(recursive: true));
    final existing = File('${library.path}/IMG_0001.JPG');
    await existing.writeAsBytes([1, 2, 3]);
    final service = MediaService();
    final hash = await service.hashFile(existing.path);

    await service.writeLibraryHashes(library.path, {hash});
    await existing.writeAsBytes([4, 5, 6]);

    final refreshed = await service.loadLibraryHashes(library.path);

    expect(refreshed, isNot(contains(hash)));
    expect(refreshed, contains(await service.hashFile(existing.path)));
  });

  test('missing library SHA index is built from library files', () async {
    final library = await Directory.systemTemp.createTemp('kinesis-index-');
    addTearDown(() => library.delete(recursive: true));
    final existing = File('${library.path}/IMG_0001.JPG');
    await existing.writeAsBytes([1, 2, 3]);
    final service = MediaService();

    final hashes = await service.loadLibraryHashes(library.path);

    expect(hashes, contains(await service.hashFile(existing.path)));
    expect(await File('${library.path}/.kinesis/index.json').exists(), isTrue);
  });

  test('scan marks source files whose hashes exist in the library', () async {
    final source = await Directory.systemTemp.createTemp('kinesis-source-');
    addTearDown(() => source.delete(recursive: true));
    final file = File('${source.path}/IMG_0001.JPG');
    await file.writeAsBytes([1, 2, 3]);

    final service = MediaService();
    final items = await service.scan(
      source.path,
      existingHashes: {await service.hashFile(file.path)},
    );

    expect(items.single.jpeg!.alreadyExists, isTrue);
  });

  test('copyAndVerify places media in the requested target template', () async {
    final source = await Directory.systemTemp.createTemp('kinesis-copy-');
    final library = await Directory.systemTemp.createTemp('kinesis-library-');
    addTearDown(() async {
      await source.delete(recursive: true);
      await library.delete(recursive: true);
    });
    final jpeg = File('${source.path}/IMG_0001.JPG');
    final cr3 = File('${source.path}/IMG_0001.CR3');
    await jpeg.writeAsBytes([1, 2, 3]);
    await cr3.writeAsBytes([4, 5, 6]);
    final service = MediaService();

    final jpegAsset = await service.copyAndVerify(
      MediaFile(path: jpeg.path, kind: MediaKind.jpeg),
      library.path,
      'JPEG/{year}',
    );
    final cr3Asset = await service.copyAndVerify(
      MediaFile(path: cr3.path, kind: MediaKind.cr3),
      library.path,
      'CRAW/{year}',
    );

    expect(jpegAsset.path, contains('/JPEG/'));
    expect(cr3Asset.path, contains('/CRAW/'));
    expect(await File(jpegAsset.path).readAsBytes(), [1, 2, 3]);
    expect(await File(cr3Asset.path).readAsBytes(), [4, 5, 6]);
  });
}
