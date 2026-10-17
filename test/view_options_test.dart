import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/domain/media.dart';
import 'package:kinesis/domain/view_options.dart';

void main() {
  final oldest = DateTime(2024, 1, 2, 8);
  final newest = DateTime(2025, 4, 3, 18);
  final files = [
    MediaFile(
      path: '/library/IMG_02.JPG',
      kind: MediaKind.jpeg,
      sizeBytes: 200,
      captureDate: oldest,
    ),
    MediaFile(
      path: '/library/IMG_01.JPG',
      kind: MediaKind.jpeg,
      sizeBytes: 100,
      captureDate: newest,
    ),
    const MediaFile(path: '/library/NO_DATE.JPG', kind: MediaKind.jpeg),
  ];

  test('files sort by capture date and keep missing dates last', () {
    expect(
      MediaViewOrder.sortFiles(
        files,
        MediaSortOrder.captureNewest,
      ).map((file) => file.name),
      ['IMG_01.JPG', 'IMG_02.JPG', 'NO_DATE.JPG'],
    );
    expect(
      MediaViewOrder.sortFiles(
        files,
        MediaSortOrder.captureOldest,
      ).map((file) => file.name),
      ['IMG_02.JPG', 'IMG_01.JPG', 'NO_DATE.JPG'],
    );
  });

  test('files sort by size in either direction with deterministic ties', () {
    final tied = [
      const MediaFile(
        path: '/library/B.JPG',
        kind: MediaKind.jpeg,
        sizeBytes: 20,
      ),
      const MediaFile(
        path: '/library/A.JPG',
        kind: MediaKind.jpeg,
        sizeBytes: 20,
      ),
      const MediaFile(path: '/library/UNKNOWN.JPG', kind: MediaKind.jpeg),
    ];
    expect(
      MediaViewOrder.sortFiles(
        tied,
        MediaSortOrder.sizeLargest,
      ).map((file) => file.name),
      ['A.JPG', 'B.JPG', 'UNKNOWN.JPG'],
    );
    expect(
      MediaViewOrder.sortFiles(
        files,
        MediaSortOrder.sizeSmallest,
      ).map((file) => file.name),
      ['IMG_01.JPG', 'IMG_02.JPG', 'NO_DATE.JPG'],
    );
  });

  test('grouping puts days newest-first and unknown dates last', () {
    final groups = MediaViewOrder.groupByCaptureDate(
      files,
      (file) => file.captureDate,
    );
    expect(groups.map((group) => group.label), [
      '2025-04-03',
      '2024-01-02',
      'Unknown date',
    ]);
    expect(groups.first.items.single.name, 'IMG_01.JPG');
  });

  test('paired ingest item uses JPEG date and combined byte size', () {
    final jpeg = MediaFile(
      path: '/source/IMG_01.JPG',
      kind: MediaKind.jpeg,
      sizeBytes: 100,
      captureDate: newest,
    );
    final raw = MediaFile(
      path: '/source/IMG_01.CR3',
      kind: MediaKind.cr3,
      sizeBytes: 900,
    );
    final paired = ReviewItem(jpeg: jpeg, cr3: raw);
    final other = ReviewItem(
      single: MediaFile(
        path: '/source/IMG_02.PNG',
        kind: MediaKind.image,
        sizeBytes: 500,
        captureDate: oldest,
      ),
    );

    expect(paired.captureDate, newest);
    expect(paired.sizeBytes, 1000);
    expect(
      MediaViewOrder.sortReviewItemIndices([
        paired,
        other,
      ], MediaSortOrder.sizeLargest),
      [0, 1],
    );
    expect(
      MediaViewOrder.sortReviewItemIndices([
        paired,
        other,
      ], MediaSortOrder.captureNewest),
      [0, 1],
    );
  });

  test('model copies preserve scan metadata', () {
    final file = files.first;
    expect(file.withHash('hash').sizeBytes, file.sizeBytes);
    expect(file.withHash('hash').captureDate, file.captureDate);
    expect(file.withExistingStatus(true).sizeBytes, file.sizeBytes);
    expect(file.withExistingStatus(true).captureDate, file.captureDate);
  });
}
