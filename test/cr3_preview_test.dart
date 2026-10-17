import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/services/cr3_preview.dart';

Uint8List _jpeg(int width, int height, {int payload = 32}) {
  final bytes = BytesBuilder()
    ..add([0xFF, 0xD8])
    ..add([
      0xFF,
      0xC0,
      0x00,
      0x11,
      0x08,
      height >> 8,
      height & 0xFF,
      width >> 8,
      width & 0xFF,
      0x03,
      0x01,
      0x11,
      0x00,
      0x02,
      0x11,
      0x00,
      0x03,
      0x11,
      0x00,
    ])
    ..add([
      0xFF,
      0xDA,
      0x00,
      0x0C,
      0x03,
      0x01,
      0x00,
      0x02,
      0x11,
      0x03,
      0x11,
      0x00,
      0x3F,
      0x00,
    ]);
  for (var index = 0; index < payload; index++) {
    bytes.addByte(index & 0x7F);
  }
  bytes.add([0xFF, 0xD9]);
  return bytes.toBytes();
}

void main() {
  test('extracts the largest preview at or below 2048px', () {
    final thumbnail = _jpeg(160, 120);
    final full = _jpeg(6000, 4000);
    final preview = _jpeg(1620, 1080);
    final file =
        (BytesBuilder()
              ..add([0x00, 0x01, 0x02])
              ..add(thumbnail)
              ..add([0x03, 0x04])
              ..add(full)
              ..add([0x05, 0x06])
              ..add(preview)
              ..add([0x07]))
            .toBytes();

    expect(extractCr3Preview(file), preview);
  });

  test('falls back to the largest embedded JPEG when all are large', () {
    final thumbnail = _jpeg(160, 120);
    final full = _jpeg(6000, 4000);
    final larger = _jpeg(4000, 3000, payload: 64);
    final file =
        (BytesBuilder()
              ..add(thumbnail)
              ..add(full)
              ..add(larger))
            .toBytes();

    expect(extractCr3Preview(file), larger);
  });

  test('returns null when no embedded JPEG is present', () {
    expect(extractCr3Preview(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });

  test('ignores JPEG-like data without a readable frame header', () {
    final valid = _jpeg(1620, 1080);
    final file =
        (BytesBuilder()
              ..add([0xFF, 0xD8, 0xFF, 0x00, 0xFF, 0xD9])
              ..add(valid))
            .toBytes();

    expect(extractCr3Preview(file), valid);
  });
}
