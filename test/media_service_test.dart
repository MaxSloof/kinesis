import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}
