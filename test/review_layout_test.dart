import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/main.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakeFilePicker extends FilePicker with MockPlatformInterfaceMixin {
  _FakeFilePicker(this.path);
  final String path;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => path;
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  testWidgets('review actions are not covered by the floating button on a '
      'phone-sized screen', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('kinesis_layout_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/IMG_0001.jpg').writeAsBytesSync([0xff, 0xd8, 0xff, 0xd9]);
    File('${dir.path}/IMG_0001.CR3').writeAsBytesSync(List.filled(64, 0));
    FilePicker.platform = _FakeFilePicker(dir.path);
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    await tester.pumpWidget(const KinesisApp());
    await tester.tap(find.text('Choose source folder'));
    for (
      var i = 0;
      i < 20 && find.textContaining('Keep JPEG').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }

    final fab = tester.getRect(find.byType(FloatingActionButton));
    for (final label in ['Keep both', 'Keep JPEG', 'Keep CR3', 'Delete both']) {
      final action = tester.getRect(
        find.ancestor(
          of: find.textContaining(label),
          matching: find.byType(FilledButton),
        ),
      );
      expect(
        action.overlaps(fab),
        isFalse,
        reason: '"$label" ($action) is covered by the FAB ($fab)',
      );
    }
  });
}
