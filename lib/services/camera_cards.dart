import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

class CameraCard {
  const CameraCard({required this.name, required this.path});

  final String name;
  final String path;
}

/// Directories whose children are candidate mounted volumes. [user] is the
/// current user's name, used by Linux's per-user mount points.
List<String> volumeParents(String operatingSystem, {String? user}) =>
    switch (operatingSystem) {
      'macos' => ['/Volumes'],
      'linux' => [
        if (user != null && user.isNotEmpty) ...[
          '/run/media/$user',
          '/media/$user',
        ],
        '/media',
        '/mnt',
      ],
      _ => const [],
    };

/// Candidate volume roots under [parents], i.e. their child directories. The
/// parents themselves are never candidates, and a volume that resolves to the
/// filesystem root (macOS lists the boot volume as `/Volumes/<name> -> /`) is
/// skipped.
Future<List<String>> listVolumeRoots(Iterable<String> parents) async {
  final roots = <String>{};
  for (final parent in parents) {
    try {
      await for (final entity in Directory(parent).list(followLinks: false)) {
        final isDirectory =
            entity is Directory ||
            (entity is Link && await FileSystemEntity.isDirectory(entity.path));
        if (!isDirectory) continue;
        if (await Directory(entity.path).resolveSymbolicLinks() ==
            path.rootPrefix(entity.path)) {
          continue;
        }
        roots.add(entity.path);
      }
    } on FileSystemException {
      // The mount directory doesn't exist on this machine.
    }
  }
  return roots.toList()..sort();
}

/// The volumes in [volumeRoots] that have a `DCIM` folder (any letter case) at
/// their root, which is how cameras lay out their cards.
Future<List<CameraCard>> findCameraCards(Iterable<String> volumeRoots) async {
  final cards = <CameraCard>[];
  for (final root in volumeRoots) {
    try {
      final hasDcim = await Directory(root)
          .list(followLinks: false)
          .any(
            (entity) =>
                entity is Directory &&
                path.basename(entity.path).toLowerCase() == 'dcim',
          );
      if (hasDcim) {
        cards.add(CameraCard(name: path.basename(root), path: root));
      }
    } on FileSystemException catch (error) {
      debugPrint('[cards] could not read $root: $error');
    }
  }
  return cards;
}

/// Looks for mounted camera cards on this machine. There is no polling; callers
/// re-check when the source screen is shown or the user asks.
Future<List<CameraCard>> detectCameraCards({
  String? operatingSystem,
  Map<String, String>? environment,
}) async {
  final os = operatingSystem ?? Platform.operatingSystem;
  if (os == 'windows') {
    return findCameraCards([
      for (
        var letter = 'D'.codeUnitAt(0);
        letter <= 'Z'.codeUnitAt(0);
        letter++
      )
        '${String.fromCharCode(letter)}:\\',
    ]);
  }
  final env = environment ?? Platform.environment;
  final roots = await listVolumeRoots(
    volumeParents(os, user: env['USER'] ?? env['LOGNAME']),
  );
  return findCameraCards(roots);
}
