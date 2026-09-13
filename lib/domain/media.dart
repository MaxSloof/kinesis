import 'dart:io';

enum MediaKind { jpeg, cr3, image, video }

enum ReviewDecision { keepBoth, keepJpeg, keepCr3, deleteBoth }

class MediaFile {
  const MediaFile({
    required this.path,
    required this.kind,
    this.hash,
    this.alreadyExists = false,
  });

  final String path;
  final MediaKind kind;
  final String? hash;
  final bool alreadyExists;

  String get name => File(path).uri.pathSegments.last;
  String get stem => name.substring(0, name.lastIndexOf('.')).toLowerCase();

  MediaFile withHash(String value) => MediaFile(
    path: path,
    kind: kind,
    hash: value,
    alreadyExists: alreadyExists,
  );

  MediaFile withExistingStatus(bool value) =>
      MediaFile(path: path, kind: kind, hash: hash, alreadyExists: value);
}

class ReviewItem {
  const ReviewItem({this.jpeg, this.cr3, this.single});

  final MediaFile? jpeg;
  final MediaFile? cr3;
  final MediaFile? single;

  bool get isPair => jpeg != null || cr3 != null;
  List<MediaFile> get files =>
      [jpeg, cr3, single].whereType<MediaFile>().toList();
  String get label => files.map((file) => file.name).join(' + ');
}

class ImportPlan {
  const ImportPlan({
    required this.toImport,
    required this.toDelete,
    required this.skipped,
  });

  final List<MediaFile> toImport;
  final List<MediaFile> toDelete;
  final List<MediaFile> skipped;
}

class ImportPlanner {
  const ImportPlanner();

  ImportPlan plan(ReviewItem item, ReviewDecision decision) {
    final selected = switch (decision) {
      ReviewDecision.keepBoth => item.files,
      ReviewDecision.keepJpeg => item.jpeg == null ? item.files : [item.jpeg!],
      ReviewDecision.keepCr3 => item.cr3 == null ? item.files : [item.cr3!],
      ReviewDecision.deleteBoth => const <MediaFile>[],
    };
    return ImportPlan(
      toImport: selected,
      toDelete: item.files,
      skipped: const [],
    );
  }
}
