import 'dart:convert';
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

  test(
    'listLibraryMedia includes existing files throughout the library',
    () async {
      final library = await Directory.systemTemp.createTemp('kinesis-library-');
      addTearDown(() => library.delete(recursive: true));
      final jpeg = File('${library.path}/JPEG/2026/IMG_0001.JPG');
      final raw = File('${library.path}/CRAW/2026/IMG_0001.CR3');
      final trashed = File('${library.path}/.kinesis-trash/IMG_0002.JPG');
      final staged = File('${library.path}/.kinesis-staging/IMG_0003.JPG');
      await jpeg.create(recursive: true);
      await raw.create(recursive: true);
      await trashed.create(recursive: true);
      await staged.create(recursive: true);
      final service = MediaService();

      final media = await service.listLibraryMedia(library.path);

      expect(media.map((file) => file.path).toSet(), {jpeg.path, raw.path});
      expect(media.map((file) => file.kind).toSet(), {
        MediaKind.jpeg,
        MediaKind.cr3,
      });
    },
  );

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

  test('library SHA index refreshes after a file is removed', () async {
    final library = await Directory.systemTemp.createTemp('kinesis-index-');
    addTearDown(() => library.delete(recursive: true));
    final existing = File('${library.path}/IMG_0001.JPG');
    await existing.writeAsBytes([1, 2, 3]);
    final service = MediaService();
    final hash = await service.hashFile(existing.path);

    expect(await service.loadLibraryHashes(library.path), contains(hash));
    await existing.delete();

    expect(
      await service.loadLibraryHashes(library.path),
      isNot(contains(hash)),
    );
    expect(await service.libraryHashesBySize(library.path), isEmpty);
  });

  test(
    'imported media updates the index without rehashing old files',
    () async {
      final library = await Directory.systemTemp.createTemp('kinesis-index-');
      addTearDown(() => library.delete(recursive: true));
      final existing = File('${library.path}/IMG_0001.JPG');
      await existing.writeAsBytes([1, 2, 3]);
      final service = MediaService();
      final existingHash = await service.hashFile(existing.path);
      await service.loadLibraryHashes(library.path);
      await existing.delete();

      final imported = File('${library.path}/IMG_0002.JPG');
      await imported.writeAsBytes([4, 5, 6]);
      final importedHash = await service.hashFile(imported.path);
      await service.writeImportedAssetsToLibraryIndex(library.path, [
        ImportedAsset(
          hash: importedHash,
          path: imported.path,
          kind: MediaKind.jpeg,
        ),
      ]);

      final index =
          jsonDecode(
                await File(
                  '${library.path}/.kinesis/index.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final entries = (index['files'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(entries, hasLength(2));
      expect(entries.map((entry) => entry['hash']), contains(existingHash));
      expect(entries.map((entry) => entry['hash']), contains(importedHash));

      expect(await service.loadLibraryHashes(library.path), {importedHash});
    },
  );

  test('concurrent library index loads share the same work', () async {
    final library = await Directory.systemTemp.createTemp('kinesis-index-');
    addTearDown(() => library.delete(recursive: true));
    await File('${library.path}/IMG_0001.JPG').writeAsBytes([1, 2, 3]);
    final service = MediaService();

    final first = service.loadLibraryHashes(library.path);
    final second = service.loadLibraryHashes(library.path);

    expect(identical(first, second), isTrue);
    expect(await first, isNotEmpty);
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

  test(
    'markExisting hashes only source files with a matching library size',
    () async {
      final source = await Directory.systemTemp.createTemp('kinesis-source-');
      addTearDown(() => source.delete(recursive: true));
      final matching = File('${source.path}/IMG_0001.JPG');
      final different = File('${source.path}/IMG_0002.JPG');
      await matching.writeAsBytes([1, 2, 3]);
      await different.writeAsBytes([4, 5, 6, 7]);
      final service = MediaService();
      final items = await service.scan(source.path);

      final marked = await service.markExisting(items, <int, Set<String>>{
        3: {await service.hashFile(matching.path)},
      });

      expect(marked[0].jpeg!.alreadyExists, isTrue);
      expect(marked[1].jpeg!.alreadyExists, isFalse);
    },
  );

  test('libraryHashesBySize reads hashes from the destination index', () async {
    final library = await Directory.systemTemp.createTemp('kinesis-library-');
    addTearDown(() => library.delete(recursive: true));
    final file = File('${library.path}/IMG_0001.JPG');
    await file.writeAsBytes([1, 2, 3]);
    final service = MediaService();

    final hashes = await service.libraryHashesBySize(library.path);

    expect(hashes[3], contains(await service.hashFile(file.path)));
  });

  test('destination folders maintain independent SHA indexes', () async {
    final library = await Directory.systemTemp.createTemp('kinesis-library-');
    addTearDown(() => library.delete(recursive: true));
    final jpeg = File('${library.path}/JPEG/IMG_0001.JPG');
    final cr3 = File('${library.path}/CRAW/IMG_0001.CR3');
    await jpeg.parent.create(recursive: true);
    await cr3.parent.create(recursive: true);
    await jpeg.writeAsBytes([1, 2, 3]);
    await cr3.writeAsBytes([4, 5, 6]);
    final service = MediaService();

    final jpegHashes = await service.loadLibraryHashes('${library.path}/JPEG');
    final cr3Hashes = await service.loadLibraryHashes('${library.path}/CRAW');

    expect(jpegHashes, {await service.hashFile(jpeg.path)});
    expect(cr3Hashes, {await service.hashFile(cr3.path)});
    expect(
      await File('${library.path}/JPEG/.kinesis/index.json').exists(),
      isTrue,
    );
    expect(
      await File('${library.path}/CRAW/.kinesis/index.json').exists(),
      isTrue,
    );
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
