import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/domain/destination_template.dart';
import 'package:kinesis/domain/media.dart';
import 'package:kinesis/services/media_service.dart';

String expand(
  String template, {
  String name = 'IMG_0001.CR3',
  String shoot = '',
  String? camera,
}) => expandDestinationTemplate(
  template,
  DateTime(2026, 10, 7),
  name,
  'DCIM',
  shoot: shoot,
  camera: camera,
);

void main() {
  group('tokens', () {
    test('the date and name tokens are unchanged', () {
      expect(
        expand('{year}/{year}-{month}-{day}/{sourceFolder}/{originalName}'),
        '2026/2026-10-07/DCIM/IMG_0001.CR3',
      );
    });

    test('{ext} is the lower-case extension without the dot', () {
      expect(expand('{ext}/{year}'), 'cr3/2026');
      expect(expand('{ext}', name: 'clip.MP4'), 'mp4');
      expect(expand('x{ext}', name: 'README'), 'x');
    });

    test('{shoot} is inserted in place', () {
      expect(
        expand('{year}/{shoot}/{day}', shoot: 'Smith wedding'),
        '2026/Smith wedding/07',
      );
      expect(expand('{year}-{shoot}', shoot: 'Trip'), '2026-Trip');
    });

    test('{camera} uses the model and falls back to Unknown camera', () {
      expect(expand('{camera}', camera: 'Canon EOS R5'), 'Canon EOS R5');
      expect(expand('{camera}'), 'Unknown camera');
      expect(expand('{camera}', camera: '  '), 'Unknown camera');
      expect(expand('{camera}', camera: '../'), 'Unknown camera');
    });
  });

  group('empty {shoot}', () {
    test('a folder that is only the shoot is dropped', () {
      expect(expand('{year}/{shoot}/{day}'), '2026/07');
      expect(expand('{shoot}/{year}'), '2026');
      expect(expand('{year}/{shoot}'), '2026');
    });

    test('the separators after the token go with it', () {
      expect(expand('{shoot} - {year}'), '2026');
      expect(expand('{year}-{shoot}-{day}'), '2026-07');
      expect(expand('{year}/{shoot}_{day}'), '2026/07');
    });

    test('separators left dangling at the end are trimmed', () {
      expect(expand('{year} {shoot}'), '2026');
      expect(expand('{year}/{day} - {shoot}'), '2026/07');
    });

    test('a shoot made only of unsafe characters counts as empty', () {
      expect(expand('{year}/{shoot}/{day}', shoot: ' .. '), '2026/07');
    });
  });

  group('sanitising', () {
    test('path separators and unsafe characters are replaced', () {
      expect(
        sanitizePathComponent('a/b\\c:d*e?f"g<h>i|j'),
        'a-b-c-d-e-f-g-h-i-j',
      );
      expect(sanitizePathComponent('tab\there\nnow'), 'tab-here-now');
      expect(sanitizePathComponent('  many   spaces  '), 'many spaces');
    });

    test('dots cannot make a folder that climbs out', () {
      expect(sanitizePathComponent('..'), '');
      expect(sanitizePathComponent('../x'), 'x');
    });

    test('an embedded separator stays inside one folder', () {
      expect(expand('{year}/{shoot}', shoot: '../../etc'), '2026/etc');
    });
  });

  group('camera names', () {
    test('the make is not repeated', () {
      expect(cameraName('Canon', 'Canon EOS R5'), 'Canon EOS R5');
      expect(cameraName('NIKON CORPORATION', 'NIKON D850'), 'NIKON D850');
      expect(cameraName('SONY', 'ILCE-7M4'), 'SONY ILCE-7M4');
    });

    test('missing parts are tolerated', () {
      expect(cameraName(null, 'EOS R5'), 'EOS R5');
      expect(cameraName('Canon', null), 'Canon');
      expect(cameraName('', ' '), isNull);
      expect(cameraName('Canon\u0000', 'Canon EOS R5\u0000'), 'Canon EOS R5');
    });
  });

  group('copyAndVerify', () {
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

    test('files into shoot, camera and type folders', () async {
      final file = File('${source.path}/IMG_0001.CR3')
        ..writeAsBytesSync([1, 2, 3]);
      final asset = await MediaService().copyAndVerify(
        MediaFile(path: file.path, kind: MediaKind.cr3),
        library.path,
        '{shoot}/{camera}/{ext}',
        shoot: 'Smith',
        cameraModel: 'Canon EOS R5',
      );
      expect(asset.path, '${library.path}/Smith/Canon EOS R5/cr3/IMG_0001.CR3');
    });

    test('an empty shoot leaves no empty folder', () async {
      final file = File('${source.path}/IMG_0001.CR3')
        ..writeAsBytesSync([1, 2, 3]);
      final asset = await MediaService().copyAndVerify(
        MediaFile(path: file.path, kind: MediaKind.cr3),
        library.path,
        '{year}/{shoot}/{ext}',
        captureDate: DateTime(2026, 1, 2),
      );
      expect(asset.path, '${library.path}/2026/cr3/IMG_0001.CR3');
    });

    test('templates that climb out of the library are refused', () async {
      final file = File('${source.path}/IMG_0001.CR3')
        ..writeAsBytesSync([1, 2, 3]);
      final file2 = MediaFile(path: file.path, kind: MediaKind.cr3);
      for (final template in ['../out', '{year}/../../out', '/abs']) {
        await expectLater(
          MediaService().copyAndVerify(file2, library.path, template),
          throwsA(isA<FileSystemException>()),
          reason: template,
        );
      }
    });

    test('a shoot name cannot escape the library', () async {
      final file = File('${source.path}/IMG_0001.CR3')
        ..writeAsBytesSync([1, 2, 3]);
      final asset = await MediaService().copyAndVerify(
        MediaFile(path: file.path, kind: MediaKind.cr3),
        library.path,
        '{shoot}',
        shoot: '../../escape',
      );
      expect(asset.path.startsWith('${library.path}/'), isTrue);
      expect(File(asset.path).parent.parent.path, library.path);
    });
  });
}
