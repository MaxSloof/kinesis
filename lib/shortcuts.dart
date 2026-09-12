import 'package:flutter/services.dart';

LogicalKeyboardKey logicalKeyForShortcut(String shortcut) {
  if (shortcut.length != 1) {
    throw ArgumentError.value(shortcut, 'shortcut', 'must be one character');
  }
  final codeUnit = shortcut.toLowerCase().codeUnitAt(0);
  if (codeUnit < 0x61 || codeUnit > 0x7a) {
    throw ArgumentError.value(shortcut, 'shortcut', 'must be an A-Z letter');
  }
  return LogicalKeyboardKey(codeUnit);
}
