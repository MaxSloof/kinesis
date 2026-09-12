import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/shortcuts.dart';

void main() {
  test('default shortcut labels resolve to Flutter logical letter keys', () {
    expect(logicalKeyForShortcut('A'), LogicalKeyboardKey.keyA);
    expect(logicalKeyForShortcut('s'), LogicalKeyboardKey.keyS);
    expect(logicalKeyForShortcut('D'), LogicalKeyboardKey.keyD);
    expect(logicalKeyForShortcut('f'), LogicalKeyboardKey.keyF);
  });

  test('shortcut labels reject non-letter values', () {
    expect(() => logicalKeyForShortcut('AA'), throwsArgumentError);
    expect(() => logicalKeyForShortcut('1'), throwsArgumentError);
  });
}
