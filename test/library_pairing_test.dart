import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/main.dart';
import 'package:kinesis/services/media_service.dart';

void main() {
  testWidgets('library pairs a CR3 with its JPEG across split roots', (
    tester,
  ) async {
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('kinesis-split-'),
    );
    final jpeg = File('${root!.path}/JPEG/2026/2026-01-02/IMG_0001.JPG');
    final raw = File('${root.path}/CRAW/2026/2026-01-02/IMG_0001.CR3');
    await tester.runAsync(() async {
      await jpeg.parent.create(recursive: true);
      await raw.parent.create(recursive: true);
      await jpeg.writeAsBytes([0xFF, 0xD8, 0xFF]);
      await raw.writeAsBytes([1, 2, 3]);
    });

    await tester.binding.setSurfaceSize(const Size(600, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(
          libraryPath: root.path,
          media: MediaService(),
          jpegRoot: '${root.path}/JPEG',
          rawRoot: '${root.path}/CRAW',
        ),
      ),
    );

    for (var index = 0; index < 60; index++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('IMG_0001.CR3').evaluate().isNotEmpty) break;
    }
    await tester.pump();

    expect(find.text('IMG_0001.JPG'), findsOneWidget);
    expect(find.text('IMG_0001.CR3'), findsOneWidget);
    // One image for the JPEG tile and one for the CR3 tile using that JPEG.
    expect(find.byType(Image), findsNWidgets(2));

    await tester.runAsync(() => root.delete(recursive: true));
  });
}
