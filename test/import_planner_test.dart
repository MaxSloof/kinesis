import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/domain/media.dart';

void main() {
  const jpeg = MediaFile(
    path: '/camera/IMG_001.jpg',
    kind: MediaKind.jpeg,
    hash: 'jpeg',
  );
  const cr3 = MediaFile(
    path: '/camera/IMG_001.cr3',
    kind: MediaKind.cr3,
    hash: 'raw',
  );
  const item = ReviewItem(jpeg: jpeg, cr3: cr3);
  const planner = ImportPlanner();

  test(
    'keeping JPEG imports only it and plans both source files for deletion',
    () {
      final plan = planner.plan(item, ReviewDecision.keepJpeg);
      expect(plan.toImport, [jpeg]);
      expect(plan.toDelete, [jpeg, cr3]);
    },
  );

  test('planning does not require checksums before review', () {
    final plan = planner.plan(item, ReviewDecision.keepBoth);
    expect(plan.toImport, [jpeg, cr3]);
    expect(plan.skipped, isEmpty);
    expect(plan.toDelete, [jpeg, cr3]);
  });

  test(
    'delete both does not import and schedules every paired source file',
    () {
      final plan = planner.plan(item, ReviewDecision.deleteBoth);
      expect(plan.toImport, isEmpty);
      expect(plan.toDelete, [jpeg, cr3]);
    },
  );

  test('single media keeps its only file for every keep decision', () {
    const video = MediaFile(path: '/camera/clip.mov', kind: MediaKind.video);
    final plan = planner.plan(
      const ReviewItem(single: video),
      ReviewDecision.keepCr3,
    );
    expect(plan.toImport, [video]);
    expect(plan.toDelete, [video]);
  });

  test('confirmed duplicate is deleted without being copied', () {
    const duplicate = MediaFile(
      path: '/camera/IMG_002.jpg',
      kind: MediaKind.jpeg,
      alreadyExists: true,
    );

    final plan = planner.plan(
      const ReviewItem(single: duplicate),
      ReviewDecision.keepBoth,
    );

    expect(plan.toImport, isEmpty);
    expect(plan.toDelete, [duplicate]);
    expect(plan.skipped, [duplicate]);
  });

  test('half-duplicate pair defaults to deleting both sources', () {
    const duplicateJpeg = MediaFile(
      path: '/camera/IMG_003.jpg',
      kind: MediaKind.jpeg,
      alreadyExists: true,
    );
    const freshCr3 = MediaFile(
      path: '/camera/IMG_003.cr3',
      kind: MediaKind.cr3,
    );
    const halfDuplicate = ReviewItem(jpeg: duplicateJpeg, cr3: freshCr3);

    expect(halfDuplicate.isDuplicate, isTrue);
    final plan = planner.plan(halfDuplicate, ReviewDecision.deleteBoth);

    expect(plan.toImport, isEmpty);
    expect(plan.toDelete, [duplicateJpeg, freshCr3]);
  });

  test('overriding a half-duplicate pair imports only the missing half', () {
    const duplicateJpeg = MediaFile(
      path: '/camera/IMG_004.jpg',
      kind: MediaKind.jpeg,
      alreadyExists: true,
    );
    const freshCr3 = MediaFile(
      path: '/camera/IMG_004.cr3',
      kind: MediaKind.cr3,
    );
    const halfDuplicate = ReviewItem(jpeg: duplicateJpeg, cr3: freshCr3);

    final plan = planner.plan(halfDuplicate, ReviewDecision.keepBoth);

    expect(plan.toImport, [freshCr3]);
    expect(plan.toDelete, [duplicateJpeg, freshCr3]);
  });

  test('fully duplicate pair is never copied', () {
    const duplicateJpeg = MediaFile(
      path: '/camera/IMG_005.jpg',
      kind: MediaKind.jpeg,
      alreadyExists: true,
    );
    const duplicateCr3 = MediaFile(
      path: '/camera/IMG_005.cr3',
      kind: MediaKind.cr3,
      alreadyExists: true,
    );

    final plan = planner.plan(
      const ReviewItem(jpeg: duplicateJpeg, cr3: duplicateCr3),
      ReviewDecision.keepBoth,
    );

    expect(plan.toImport, isEmpty);
    expect(plan.toDelete, [duplicateJpeg, duplicateCr3]);
  });

  test('default decisions delete duplicate items only', () {
    const duplicate = MediaFile(
      path: '/camera/IMG_006.jpg',
      kind: MediaKind.jpeg,
      alreadyExists: true,
    );
    final items = [const ReviewItem(single: duplicate), item];

    expect(ImportPlanner.defaultDecisions(items), {
      0: ReviewDecision.deleteBoth,
    });
  });

  test('duplicate cleanup deletes a new CR3 when its JPEG is in library', () {
    const cr3 = MediaFile(path: '/source/IMG_007.cr3', kind: MediaKind.cr3);
    const libraryJpeg = MediaFile(
      path: '/library/IMG_007.jpg',
      kind: MediaKind.jpeg,
    );
    const item = ReviewItem(cr3: cr3, existingJpeg: libraryJpeg);

    expect(ImportPlanner.needsDuplicateCleanup(item), isTrue);
    expect(
      ImportPlanner.duplicateCleanupDecision(item),
      ReviewDecision.deleteBoth,
    );
    expect(ImportPlanner.defaultDecisions([item]), {
      0: ReviewDecision.deleteBoth,
    });
  });

  test('matching library JPEG is reference-only when importing a CR3', () {
    const cr3 = MediaFile(path: '/source/IMG_009.cr3', kind: MediaKind.cr3);
    const libraryJpeg = MediaFile(
      path: '/library/IMG_009.jpg',
      kind: MediaKind.jpeg,
      alreadyExists: true,
    );
    const item = ReviewItem(cr3: cr3, existingJpeg: libraryJpeg);

    final plan = planner.plan(item, ReviewDecision.keepCr3);

    expect(plan.toImport, [cr3]);
    expect(plan.toDelete, [cr3]);
    expect(plan.skipped, isEmpty);
    expect(plan.toImport, isNot(contains(libraryJpeg)));
  });

  test('duplicate cleanup keeps new media and removes its duplicate pair', () {
    const duplicateJpeg = MediaFile(
      path: '/source/IMG_008.jpg',
      kind: MediaKind.jpeg,
      alreadyExists: true,
    );
    const newCr3 = MediaFile(path: '/source/IMG_008.cr3', kind: MediaKind.cr3);
    const item = ReviewItem(jpeg: duplicateJpeg, cr3: newCr3);

    expect(
      ImportPlanner.duplicateCleanupDecision(item),
      ReviewDecision.deleteBoth,
    );
  });
}
