import 'dart:io';

import 'capture_date.dart';

enum MediaKind { jpeg, cr3, image, video }

enum ReviewDecision {
  keepBoth('Keep both'),
  keepJpeg('Keep JPEG'),
  keepCr3('Keep CR3'),
  deleteBoth('Delete both');

  const ReviewDecision(this.label);

  final String label;
}

String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 || dot == name.length - 1
      ? ''
      : name.substring(dot + 1).toUpperCase();
}

class MediaFile {
  const MediaFile({
    required this.path,
    required this.kind,
    this.displayName,
    this.relativePath,
    this.rootUri,
    this.rootName,
    this.modified,
    this.hash,
    this.alreadyExists = false,
    this.sizeBytes,
    this.captureDate,
    this.cameraModel,
  });

  final String path;
  final MediaKind kind;
  final String? displayName;
  final String? relativePath;
  final String? rootUri;
  final String? rootName;
  final DateTime? modified;
  final String? hash;
  final bool alreadyExists;
  final int? sizeBytes;
  final DateTime? captureDate;

  /// Camera make and model from the file's metadata, when it has any.
  final String? cameraModel;

  String get name => displayName ?? File(path).uri.pathSegments.last;

  /// The date this file is filed and labelled under; see [resolveCaptureDate].
  DateTime? resolvedCaptureDate([
    CaptureDateAdjustment adjustment = CaptureDateAdjustment.none,
  ]) => resolveCaptureDate(
    embedded: captureDate,
    fileNames: [name],
    modified: modified,
    adjustment: adjustment,
  );
  String get stem => name.substring(0, name.lastIndexOf('.')).toLowerCase();
  String get pairingKey =>
      '${relativePath == null ? File(path).parent.path : _relativeParent(relativePath!)}'
      '/$stem';
  MediaFile withHash(String value) => MediaFile(
    path: path,
    kind: kind,
    displayName: displayName,
    relativePath: relativePath,
    rootUri: rootUri,
    rootName: rootName,
    modified: modified,
    hash: value,
    alreadyExists: alreadyExists,
    sizeBytes: sizeBytes,
    captureDate: captureDate,
    cameraModel: cameraModel,
  );

  MediaFile withExistingStatus(bool value) => MediaFile(
    path: path,
    kind: kind,
    displayName: displayName,
    relativePath: relativePath,
    rootUri: rootUri,
    rootName: rootName,
    modified: modified,
    hash: hash,
    alreadyExists: value,
    sizeBytes: sizeBytes,
    captureDate: captureDate,
    cameraModel: cameraModel,
  );
}

String _relativeParent(String value) {
  final separator = value.lastIndexOf('/');
  return separator < 0 ? '' : value.substring(0, separator);
}

class ReviewItem {
  const ReviewItem({this.jpeg, this.cr3, this.single, this.existingJpeg});

  final MediaFile? jpeg;
  final MediaFile? cr3;
  final MediaFile? single;

  /// A JPEG with the same shot name that already lives in the destination
  /// library. It is only used for previewing, never imported or deleted.
  final MediaFile? existingJpeg;

  bool get isPair => jpeg != null || cr3 != null;

  /// True when at least one file is already present in the library. Used to
  /// default the whole pair to Delete both when re-importing a shot.
  bool get isDuplicate => files.any((file) => file.alreadyExists);
  List<MediaFile> get files =>
      [jpeg, cr3, single].whereType<MediaFile>().toList();
  String get label => files.map((file) => file.name).join(' + ');

  ReviewItem withExistingJpeg(MediaFile? value) =>
      ReviewItem(jpeg: jpeg, cr3: cr3, single: single, existingJpeg: value);

  /// The shot's name without its extension, shared by both files of a pair.
  String get displayName {
    final name = files.first.name;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// Compact format labels for the badge row, e.g. `JPEG` and `CR3` for a
  /// pair (or the RAW's own extension), or the file extension for a single image or video.
  List<String> get formats => [
    if (jpeg != null) 'JPEG',
    if (cr3 != null) _extensionOf(cr3!.name),
    for (final file in files)
      if (file.kind == MediaKind.image || file.kind == MediaKind.video)
        _extensionOf(file.name),
  ].where((format) => format.isNotEmpty).toList();

  DateTime? get captureDate => resolvedCaptureDate();

  String? get cameraModel =>
      [jpeg, cr3, single].map((file) => file?.cameraModel).nonNulls.firstOrNull;

  /// One date for every file of the item, so a JPEG and its CR3 land in the
  /// same folder.
  DateTime? resolvedCaptureDate([
    CaptureDateAdjustment adjustment = CaptureDateAdjustment.none,
  ]) {
    final media = [jpeg, cr3, single].whereType<MediaFile>().toList();
    return resolveCaptureDate(
      embedded: media.map((file) => file.captureDate).nonNulls.firstOrNull,
      fileNames: media.map((file) => file.name),
      modified: media.map((file) => file.modified).nonNulls.firstOrNull,
      adjustment: adjustment,
    );
  }

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

  /// Items eligible for the duplicate-only review action. A matching library
  /// JPEG is also relevant when reviewing a new CR3 that has no source JPEG.
  static bool needsDuplicateCleanup(ReviewItem item) =>
      item.isDuplicate || (item.existingJpeg != null && item.cr3 != null);

  /// Duplicate cleanup defaults to deleting all source files for the item.
  static ReviewDecision duplicateCleanupDecision(ReviewItem _) =>
      ReviewDecision.deleteBoth;

  /// Defaults duplicate source items to deletion. A library JPEG paired with
  /// a source CR3 also counts: it indicates the shot was already reviewed.
  static Map<int, ReviewDecision> defaultDecisions(List<ReviewItem> items) => {
    for (var index = 0; index < items.length; index++)
      if (needsDuplicateCleanup(items[index])) index: ReviewDecision.deleteBoth,
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
      skipped: selected.where((file) => file.alreadyExists).toList(),
    );
  }
}
