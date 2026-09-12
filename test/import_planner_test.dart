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
}
