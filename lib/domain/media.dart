import 'dart:io';

enum MediaKind { jpeg, cr3, image, video }

enum ReviewDecision { keepBoth, keepJpeg, keepCr3, deleteBoth }

class MediaFile {
  const MediaFile({
    required this.path,
    required this.kind,
    this.hash,
    this.alreadyExists = false,
    this.sizeBytes,
    this.captureDate,
  });

  final String path;
  final MediaKind kind;
  final String? hash;
  final bool alreadyExists;
  final int? sizeBytes;
  final DateTime? captureDate;

  String get name => File(path).uri.pathSegments.last;
  String get stem => name.substring(0, name.lastIndexOf('.')).toLowerCase();

  MediaFile withHash(String value) => MediaFile(
    path: path,
    kind: kind,
    hash: value,
    alreadyExists: alreadyExists,
    sizeBytes: sizeBytes,
    captureDate: captureDate,
  );

  MediaFile withExistingStatus(bool value) => MediaFile(
    path: path,
    kind: kind,
    hash: hash,
    alreadyExists: value,
    sizeBytes: sizeBytes,
    captureDate: captureDate,
  );
}

class ReviewItem {
  const ReviewItem({this.jpeg, this.cr3, this.single});

  final MediaFile? jpeg;
  final MediaFile? cr3;
  final MediaFile? single;

  bool get isPair => jpeg != null || cr3 != null;

  /// True when at least one file is already present in the library. Used to
  /// default the whole pair to Delete both when re-importing a shot.
  bool get isDuplicate => files.any((file) => file.alreadyExists);
  List<MediaFile> get files =>
      [jpeg, cr3, single].whereType<MediaFile>().toList();
  String get label => files.map((file) => file.name).join(' + ');
  DateTime? get captureDate =>
      jpeg?.captureDate ?? cr3?.captureDate ?? single?.captureDate;
  int? get sizeBytes {
    final media = files;
    if (media.any((file) => file.sizeBytes == null)) return null;
    return media.fold<int>(0, (total, file) => total + file.sizeBytes!);
  }
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

  /// Default review decisions for a fresh scan: any item with a file already
  /// in the library is treated as a duplicate and scheduled for deletion.
  static Map<int, ReviewDecision> defaultDecisions(List<ReviewItem> items) => {
    for (var index = 0; index < items.length; index++)
      if (items[index].isDuplicate) index: ReviewDecision.deleteBoth,
  };

  ImportPlan plan(ReviewItem item, ReviewDecision decision) {
    final selected = switch (decision) {
      ReviewDecision.keepBoth => item.files,
      ReviewDecision.keepJpeg => item.jpeg == null ? item.files : [item.jpeg!],
      ReviewDecision.keepCr3 => item.cr3 == null ? item.files : [item.cr3!],
      ReviewDecision.deleteBoth => const <MediaFile>[],
    };
    return ImportPlan(
      toImport: selected.where((file) => !file.alreadyExists).toList(),
      toDelete: item.files,
      skipped: const [],
    );
  }
}
