import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/domain/capture_date.dart';
import 'package:kinesis/domain/import_options.dart';
import 'package:kinesis/domain/media.dart';
import 'package:kinesis/services/cr3_metadata.dart';
import 'package:kinesis/services/media_service.dart';
import 'package:kinesis/widgets/import_options_dialog.dart';

void main() {
  group('resolveCaptureDate', () {
    final embedded = DateTime(2024, 1, 2, 3, 4, 5);
    final modified = DateTime(2020, 5, 6, 7, 8, 9);

    test('prefers embedded metadata over the file name and modified time', () {
      expect(
        resolveCaptureDate(
          embedded: embedded,
          fileNames: ['IMG_20261017_143000.JPG'],
          modified: modified,
        ),
        embedded,
      );
    });

    test('falls back to the file name, then the modified time', () {
      expect(
        resolveCaptureDate(
          fileNames: ['IMG_20261017_143000.JPG'],
          modified: modified,
        ),
        DateTime(2026, 10, 17, 14, 30),
      );
      expect(
        resolveCaptureDate(fileNames: ['IMG_0001.JPG'], modified: modified),
        modified,
      );
      expect(resolveCaptureDate(fileNames: ['IMG_0001.JPG']), isNull);
    });

    test('a fixed override replaces every other source', () {
      final fixed = DateTime(2000, 1, 1);
      expect(
        resolveCaptureDate(
          embedded: embedded,
          modified: modified,
          adjustment: CaptureDateAdjustment(fixed: fixed),
        ),
        fixed,
      );
    });

    test('a shift moves the resolved date, also from the fallbacks', () {
      const shift = CaptureDateAdjustment(
        shift: Duration(hours: -2, minutes: 15),
      );
      expect(
        resolveCaptureDate(embedded: embedded, adjustment: shift),
        DateTime(2024, 1, 2, 1, 19, 5),
      );
      expect(
        resolveCaptureDate(modified: modified, adjustment: shift),
        DateTime(2020, 5, 6, 5, 23, 9),
      );
    });

    test('a shift can cross midnight', () {
      expect(
        resolveCaptureDate(
          embedded: DateTime(2024, 12, 31, 23, 30),
          adjustment: const CaptureDateAdjustment(shift: Duration(hours: 1)),
        ),
        DateTime(2025, 1, 1, 0, 30),
      );
    });
  });

  group('CaptureDateAdjustment', () {
    test('describes what it does for the plan', () {
      expect(CaptureDateAdjustment.none.description, isNull);
      expect(CaptureDateAdjustment.none.isActive, isFalse);
      expect(
        CaptureDateAdjustment.shiftBy(hours: 1, minutes: 30).description,
        'Capture dates shifted by +1 h 30 min',
      );
      expect(
        CaptureDateAdjustment.shiftBy(negative: true, hours: 8).description,
        'Capture dates shifted by -8 h 0 min',
      );
      expect(
        CaptureDateAdjustment(fixed: DateTime(2026, 10, 17, 9, 5)).description,
        'Capture date set to 2026-10-17 09:05',
      );
    });

    testWidgets('the dialog returns a shift', (tester) async {
      ImportOptions? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showDialog(
                context: context,
                builder: (_) =>
                    const ImportOptionsDialog(initial: ImportOptions.none),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Shoot name'),
        ' Smith wedding ',
      );
      await tester.tap(find.text('Shift'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('−'));
      await tester.enterText(find.widgetWithText(TextField, 'Hours'), '2');
      await tester.enterText(find.widgetWithText(TextField, 'Minutes'), '30');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(result?.shoot, 'Smith wedding');
      expect(
        result?.dateAdjustment.shift,
        const Duration(hours: -2, minutes: -30),
      );
    });

    testWidgets('setting a date needs a date before it can be applied', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ImportOptionsDialog(initial: ImportOptions.none),
        ),
      );
      await tester.tap(find.text('Set date'));
      await tester.pumpAndSettle();

      final apply = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(apply.onPressed, isNull);
    });
  });

  group('dateFromFileName', () {
    test('reads camera and phone style names', () {
      expect(
        dateFromFileName('IMG_20261017_143000.jpg'),
        DateTime(2026, 10, 17, 14, 30),
      );
      expect(
        dateFromFileName('vid20261017_143001.mp4'),
        DateTime(2026, 10, 17, 14, 30, 1),
      );
      expect(
        dateFromFileName('DSC_20261017_143002.JPG'),
        DateTime(2026, 10, 17, 14, 30, 2),
      );
    });

    test('reads dashed names', () {
      expect(
        dateFromFileName('2026-10-17_14-30-00.mov'),
        DateTime(2026, 10, 17, 14, 30),
      );
      expect(
        dateFromFileName('2026-10-17-143000.mov'),
        DateTime(2026, 10, 17, 14, 30),
      );
    });

    test('rejects impossible dates and unrelated numbers', () {
      expect(dateFromFileName('IMG_20261317_143000.jpg'), isNull);
      expect(dateFromFileName('IMG_20260230_143000.jpg'), isNull);
      expect(dateFromFileName('IMG_20261017_246000.jpg'), isNull);
      expect(dateFromFileName('2026-13-17_14-30-00.mov'), isNull);
      expect(dateFromFileName('IMG_0001.JPG'), isNull);
      expect(dateFromFileName('IMG_120261017_143000.jpg'), isNull);
    });
  });

  group('CR3 capture date', () {
    test('is read from the Canon CMT2 box', () {
      final cr3 = _cr3(exifDate: '2025:03:04 05:06:07');
      expect(
        cr3MetadataFromHead(cr3).captureDate,
        DateTime(2025, 3, 4, 5, 6, 7),
      );
    });

    test('falls back to the DateTime in CMT1', () {
      final cr3 = _cr3(ifd0Date: '2025:03:04 05:06:08');
      expect(
        cr3MetadataFromHead(cr3).captureDate,
        DateTime(2025, 3, 4, 5, 6, 8),
      );
    });

    test('is null for files without metadata or with a truncated moov', () {
      expect(
        cr3MetadataFromHead(Uint8List.fromList([1, 2, 3, 4])).captureDate,
        isNull,
      );
      final cr3 = _cr3(exifDate: '2025:03:04 05:06:07');
      expect(
        cr3MetadataFromHead(
          Uint8List.sublistView(cr3, 0, cr3.length - 10),
        ).captureDate,
        isNull,
      );
    });

    test('scan reads it from disk and ignores the modified time', () async {
      final source = await Directory.systemTemp.createTemp('kinesis-cr3-');
      addTearDown(() => source.delete(recursive: true));
      final file = File('${source.path}/IMG_0001.CR3');
      await file.writeAsBytes([
        ..._cr3(exifDate: '2025:03:04 05:06:07'),
        ...List.filled(5000, 7),
      ]);

      final item = (await MediaService().scan(source.path)).single;

      expect(item.cr3!.captureDate, DateTime(2025, 3, 4, 5, 6, 7));
      expect(item.resolvedCaptureDate(), DateTime(2025, 3, 4, 5, 6, 7));
    });
  });

  group('destination folders', () {
    late Directory source;
    late Directory library;

    setUp(() async {
      source = await Directory.systemTemp.createTemp('kinesis-copy-');
      library = await Directory.systemTemp.createTemp('kinesis-library-');
    });
    tearDown(() async {
      await source.delete(recursive: true);
      await library.delete(recursive: true);
    });

    test('use the capture date, not the modified time', () async {
      final file = File('${source.path}/IMG_0001.CR3');
      await file.writeAsBytes(_cr3(exifDate: '2025:03:04 05:06:07'));
      await file.setLastModified(DateTime(2001, 2, 3));
      final item = (await MediaService().scan(source.path)).single;

      final asset = await MediaService().copyAndVerify(
        item.cr3!,
        library.path,
        '{year}/{year}-{month}-{day}',
        captureDate: item.resolvedCaptureDate(),
      );

      expect(asset.path, contains('/2025/2025-03-04/'));
    });

    test(
      'the copy gets the capture date as modified time and index entry',
      () async {
        final file = File('${source.path}/IMG_0001.CR3');
        await file.writeAsBytes(_cr3(exifDate: '2025:03:04 05:06:07'));
        final service = MediaService();
        final item = (await service.scan(source.path)).single;

        final asset = await service.copyAndVerify(
          item.cr3!,
          library.path,
          '{year}',
          captureDate: item.resolvedCaptureDate(),
        );
        await service.writeImportedAssetsToLibraryIndex(library.path, [asset]);

        final modified = File(asset.path).statSync().modified;
        expect(modified, DateTime(2025, 3, 4, 5, 6, 7));
        final index =
            jsonDecode(
                  File(
                    '${library.path}/.kinesis/index.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        final entry = (index['files'] as List).single as Map<String, dynamic>;
        expect(entry['modified'], modified.millisecondsSinceEpoch);
      },
    );

    test('a JPEG and CR3 pair share the item date', () async {
      final service = MediaService();
      final jpeg = File('${source.path}/IMG_0001.JPG')
        ..writeAsBytesSync([1, 2, 3]);
      final cr3 = File('${source.path}/IMG_0001.CR3')
        ..writeAsBytesSync(_cr3(exifDate: '2025:03:04 05:06:07'));
      await jpeg.setLastModified(DateTime(2001, 2, 3));
      final item = (await service.scan(source.path)).single;
      final date = item.resolvedCaptureDate();

      final assets = [
        for (final file in item.files)
          await service.copyAndVerify(
            file,
            library.path,
            '{year}-{month}-{day}',
            captureDate: date,
          ),
      ];

      expect(assets.map((asset) => File(asset.path).parent.path).toSet(), {
        '${library.path}/2025-03-04',
      });
      expect(cr3.existsSync(), isTrue);
    });

    test('a date in the file name is used when there is no metadata', () async {
      final file = File('${source.path}/IMG_20260102_030405.JPG')
        ..writeAsBytesSync([1, 2, 3]);
      await file.setLastModified(DateTime(2001, 2, 3));
      final item = (await MediaService().scan(source.path)).single;

      final asset = await MediaService().copyAndVerify(
        item.jpeg!,
        library.path,
        '{year}/{month}/{day}',
      );

      expect(asset.path, contains('/2026/01/02/'));
    });

    test('an adjustment applies when no item date is given', () async {
      final file = File('${source.path}/IMG_0001.JPG')
        ..writeAsBytesSync([1, 2, 3]);
      await file.setLastModified(DateTime(2001, 2, 3, 23, 30));
      final item = (await MediaService().scan(source.path)).single;

      final asset = await MediaService().copyAndVerify(
        item.jpeg!,
        library.path,
        '{year}-{month}-{day}',
        adjustment: const CaptureDateAdjustment(shift: Duration(hours: 1)),
      );

      expect(asset.path, contains('/2001-02-04/'));
    });
  });

  test('scan reads the camera from the CR3 metadata', () async {
    final source = await Directory.systemTemp.createTemp('kinesis-cam-');
    addTearDown(() => source.delete(recursive: true));
    await File(
      '${source.path}/IMG_0001.CR3',
    ).writeAsBytes(_cr3(make: 'Canon', model: 'Canon EOS R5'));

    final item = (await MediaService().scan(source.path)).single;

    expect(item.cr3!.cameraModel, 'Canon EOS R5');
    expect(item.cameraModel, 'Canon EOS R5');
  });

  test('scan reads the camera from JPEG EXIF', () async {
    final source = await Directory.systemTemp.createTemp('kinesis-cam-');
    addTearDown(() => source.delete(recursive: true));
    await File(
      '${source.path}/IMG_0001.JPG',
    ).writeAsBytes(_tiff({0x010f: 'SONY', 0x0110: 'ILCE-7M4'}));

    final item = (await MediaService().scan(source.path)).single;

    expect(item.jpeg!.cameraModel, 'SONY ILCE-7M4');
  });

  test('ReviewItem resolves one date from metadata, name and modified', () {
    final modified = DateTime(2020, 1, 1);
    final item = ReviewItem(
      jpeg: MediaFile(
        path: '/x/IMG_0001.JPG',
        kind: MediaKind.jpeg,
        modified: modified,
      ),
      cr3: MediaFile(
        path: '/x/IMG_0001.CR3',
        kind: MediaKind.cr3,
        modified: modified,
        captureDate: DateTime(2025, 3, 4),
      ),
    );
    expect(item.resolvedCaptureDate(), DateTime(2025, 3, 4));
    expect(item.captureDate, DateTime(2025, 3, 4));
  });
}

Uint8List _box(String type, List<int> payload) {
  final bytes = BytesBuilder()
    ..add((ByteData(4)..setUint32(0, payload.length + 8)).buffer.asUint8List())
    ..add(type.codeUnits)
    ..add(payload);
  return bytes.toBytes();
}

/// A little-endian TIFF whose IFD0 holds the given ASCII tags.
Uint8List _tiff(Map<int, String> tags) {
  final texts = [
    for (final value in tags.values) [...value.codeUnits, 0],
  ];
  final dataStart = 8 + 2 + 12 * tags.length + 4;
  final size = dataStart + texts.fold<int>(0, (n, t) => n + t.length);
  final bytes = ByteData(size);
  bytes.setUint8(0, 0x49);
  bytes.setUint8(1, 0x49);
  bytes.setUint16(2, 42, Endian.little);
  bytes.setUint32(4, 8, Endian.little);
  bytes.setUint16(8, tags.length, Endian.little);
  final result = bytes.buffer.asUint8List();
  var data = dataStart;
  var entry = 10;
  var index = 0;
  for (final tag in tags.keys) {
    final text = texts[index++];
    bytes.setUint16(entry, tag, Endian.little);
    bytes.setUint16(entry + 2, 2, Endian.little);
    bytes.setUint32(entry + 4, text.length, Endian.little);
    bytes.setUint32(entry + 8, data, Endian.little);
    result.setRange(data, data + text.length, text);
    data += text.length;
    entry += 12;
  }
  return result;
}

Uint8List _cr3({
  String? exifDate,
  String? ifd0Date,
  String? make,
  String? model,
}) {
  final canon = BytesBuilder()
    ..add(const [
      0x85, 0xc0, 0xb6, 0x87, 0x82, 0x0f, 0x11, 0xe0, //
      0x81, 0x11, 0xf4, 0xce, 0x46, 0x2b, 0x6a, 0x48,
    ])
    ..add(_box('CNCV', 'CanonCR3_001/00.09.00/00.00.00'.codeUnits))
    ..add(
      _box('CMT1', _tiff({0x010f: ?make, 0x0110: ?model, 0x0132: ?ifd0Date})),
    );
  if (exifDate != null) canon.add(_box('CMT2', _tiff({0x9003: exifDate})));
  final file = BytesBuilder()
    ..add(_box('ftyp', 'crx '.codeUnits + [0, 0, 0, 1]))
    ..add(_box('moov', _box('uuid', canon.toBytes())));
  return file.toBytes();
}
