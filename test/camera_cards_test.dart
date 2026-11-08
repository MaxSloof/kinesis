import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/services/camera_cards.dart';
import 'package:kinesis/widgets/camera_card_picks.dart';

void main() {
  late Directory mounts;

  setUp(() async {
    mounts = await Directory.systemTemp.createTemp('kinesis-mounts-');
  });
  tearDown(() => mounts.delete(recursive: true));

  Future<String> volume(String name, {String? dcim}) async {
    final directory = Directory('${mounts.path}/$name');
    await directory.create(recursive: true);
    if (dcim != null) await Directory('${directory.path}/$dcim').create();
    return directory.path;
  }

  test(
    'volumes with a DCIM folder are cards, whatever its letter case',
    () async {
      final upper = await volume('EOS_DIGITAL', dcim: 'DCIM');
      final lower = await volume('SD', dcim: 'dcim');

      final cards = await findCameraCards([upper, lower]);

      expect(cards.map((card) => card.name), ['EOS_DIGITAL', 'SD']);
      expect(cards.map((card) => card.path), [upper, lower]);
    },
  );

  test('a volume without DCIM is excluded', () async {
    final backup = await volume('Backup');
    await File('$backup/DCIM').writeAsString('a file, not a folder');
    final photos = await volume('Photos');
    await Directory('$photos/Pictures/DCIM').create(recursive: true);

    expect(await findCameraCards([backup, photos]), isEmpty);
  });

  test('missing or unreadable roots are ignored', () async {
    expect(await findCameraCards(['${mounts.path}/gone']), isEmpty);
  });

  test('volume roots are the children of the mount parents only', () async {
    await volume('A');
    await volume('B');
    await File('${mounts.path}/not-a-volume').writeAsString('x');

    final roots = await listVolumeRoots([mounts.path, '${mounts.path}/absent']);

    expect(roots, ['${mounts.path}/A', '${mounts.path}/B']);
  });

  test('a volume that is a link to the filesystem root is skipped', () async {
    await Link('${mounts.path}/Macintosh HD').create('/');
    await volume('A');

    expect(await listVolumeRoots([mounts.path]), ['${mounts.path}/A']);
  }, skip: Platform.isWindows);

  group('mount parents', () {
    test('linux covers per-user and shared mount points', () {
      expect(volumeParents('linux', user: 'max'), [
        '/run/media/max',
        '/media/max',
        '/media',
        '/mnt',
      ]);
    });

    test('linux without a user only uses the shared mount points', () {
      expect(volumeParents('linux'), ['/media', '/mnt']);
    });

    test('macos uses /Volumes and mobile platforms use nothing', () {
      expect(volumeParents('macos'), ['/Volumes']);
      expect(volumeParents('android'), isEmpty);
      expect(volumeParents('ios'), isEmpty);
    });
  });

  test('detection finds nothing on mobile', () async {
    expect(await detectCameraCards(operatingSystem: 'android'), isEmpty);
    expect(await detectCameraCards(operatingSystem: 'ios'), isEmpty);
  });

  testWidgets('quick picks list detected cards and select one', (tester) async {
    String? selected;
    var detections = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CameraCardPicks(
            onSelected: (path) => selected = path,
            detect: () async {
              detections++;
              return const [CameraCard(name: 'EOS_DIGITAL', path: '/v/EOS')];
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(detections, 1);

    await tester.tap(find.text('EOS_DIGITAL'));
    expect(selected, '/v/EOS');

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(detections, 2);
  });
}
