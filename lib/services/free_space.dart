import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../domain/view_options.dart';
import 'saf_storage.dart';

/// Free bytes on the volume holding [directory], or null when unknown.
typedef FreeSpaceReader = Future<int?> Function(String directory);

class FreeSpaceCheck {
  const FreeSpaceCheck({required this.requiredBytes, required this.freeBytes});

  final int requiredBytes;

  /// Null when free space can't be read; the import is then not blocked.
  final int? freeBytes;

  bool get isEnough => freeBytes == null || freeBytes! >= requiredBytes;

  String get message =>
      'Not enough free space on the library volume: the import needs '
      '${MediaViewOrder.sizeLabel(requiredBytes)} but only '
      '${MediaViewOrder.sizeLabel(freeBytes)} is free.';
}

Future<FreeSpaceCheck> checkFreeSpace({
  required String library,
  required int requiredBytes,
  FreeSpaceReader reader = readFreeBytes,
}) async => FreeSpaceCheck(
  requiredBytes: requiredBytes,
  freeBytes: requiredBytes == 0 || SafStorage.isUri(library)
      ? null
      : await reader(library),
);

/// Reads free space with `df -Pk` on macOS and Linux. Other platforms, and
/// any failure, return null so a missing reading never blocks an import.
Future<int?> readFreeBytes(String directory) async {
  if (!Platform.isMacOS && !Platform.isLinux) return null;
  try {
    var existing = path.normalize(path.absolute(directory));
    while (!await Directory(existing).exists() &&
        path.dirname(existing) != existing) {
      existing = path.dirname(existing);
    }
    final result = await Process.run('df', ['-Pk', existing]);
    if (result.exitCode != 0) return null;
    return parseDfAvailableBytes(result.stdout as String);
  } on Object catch (error) {
    debugPrint('[import] could not read free space: $error');
    return null;
  }
}

/// Available bytes from `df -Pk` output. The filesystem and mount point can
/// contain spaces, so the numeric columns are matched instead of split.
int? parseDfAvailableBytes(String output) {
  final line = RegExp(
    r'^.+?\s+\d+\s+\d+\s+(\d+)\s+\d+%\s+.+$',
    multiLine: true,
  ).firstMatch(output);
  final kilobytes = line == null ? null : int.tryParse(line[1]!);
  return kilobytes == null ? null : kilobytes * 1024;
}
