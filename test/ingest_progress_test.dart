import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/domain/ingest_progress.dart';
import 'package:kinesis/domain/media.dart';
import 'package:kinesis/services/free_space.dart';

void main() {
  group('IngestProgress', () {
    test('copy progress follows bytes, not file count', () {
      const progress = IngestProgress(
        phase: IngestProgress.copyPhase,
        done: 1,
        total: 2,
        bytesDone: 900,
        bytesTotal: 1000,
      );
      expect(progress.fraction, closeTo(0.9, 1e-9));
      expect(progress.filesLabel, '1 / 2 files');
    });

    test('falls back to file steps when sizes are unknown', () {
      const progress = IngestProgress(
        phase: IngestProgress.copyPhase,
        done: 1,
        total: 4,
      );
      expect(progress.fraction, 0.25);
      expect(progress.bytesLabel, isNull);
    });

    test('keeps growing through the Trash steps', () {
      double? at(int done, int bytesDone) => IngestProgress(
        phase: 'x',
        done: done,
        total: 4,
        copyTotal: 2,
        bytesDone: bytesDone,
        bytesTotal: 100,
      ).fraction;

      final values = [at(0, 0), at(1, 90), at(2, 100), at(3, 100), at(4, 100)];
      expect(values.first, 0);
      expect(values.last, 1);
      for (var i = 1; i < values.length; i++) {
        expect(values[i]! >= values[i - 1]!, isTrue, reason: '$values');
      }
    });

    test('an empty import has no fraction', () {
      expect(
        const IngestProgress(phase: 'x', done: 0, total: 0).fraction,
        isNull,
      );
    });

    test('shows bytes done and total', () {
      const progress = IngestProgress(
        phase: IngestProgress.copyPhase,
        done: 1,
        total: 2,
        bytesDone: 1536 * 1024,
        bytesTotal: 5 * 1024 * 1024,
      );
      expect(progress.bytesLabel, '1.5 MB / 5.0 MB');
    });

    test('totalBytes sums known sizes', () {
      expect(
        totalBytes([
          const MediaFile(path: 'a', kind: MediaKind.jpeg, sizeBytes: 10),
          const MediaFile(path: 'b', kind: MediaKind.cr3, sizeBytes: 5),
          const MediaFile(path: 'c', kind: MediaKind.video),
        ]),
        15,
      );
    });
  });

  group('free space', () {
    test('enough space passes and too little fails', () async {
      final enough = await checkFreeSpace(
        library: '/lib',
        requiredBytes: 100,
        reader: (_) async => 100,
      );
      expect(enough.isEnough, isTrue);

      final short = await checkFreeSpace(
        library: '/lib',
        requiredBytes: 2048,
        reader: (_) async => 1024,
      );
      expect(short.isEnough, isFalse);
      expect(
        short.message,
        'Not enough free space on the library volume: the import needs '
        '2.0 KB but only 1.0 KB is free.',
      );
    });

    test('unknown free space never blocks', () async {
      final check = await checkFreeSpace(
        library: '/lib',
        requiredBytes: 1 << 40,
        reader: (_) async => null,
      );
      expect(check.isEnough, isTrue);
    });

    test('SAF libraries and empty plans skip the reader', () async {
      var reads = 0;
      Future<int?> reader(String _) async {
        reads++;
        return 0;
      }

      expect(
        (await checkFreeSpace(
          library: 'content://provider/tree/primary%3ADCIM',
          requiredBytes: 100,
          reader: reader,
        )).isEnough,
        isTrue,
      );
      expect(
        (await checkFreeSpace(
          library: '/lib',
          requiredBytes: 0,
          reader: reader,
        )).isEnough,
        isTrue,
      );
      expect(reads, 0);
    });

    test('parses df -Pk output, including names with spaces', () {
      expect(
        parseDfAvailableBytes(
          'Filesystem    1024-blocks      Used Available Capacity Mounted on\n'
          '/dev/disk3s5    971350180 500000000 400000000      56% /System/Volumes/Data\n',
        ),
        400000000 * 1024,
      );
      expect(
        parseDfAvailableBytes(
          'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
          '//max@nas/My Share 1000 400 600 40% /Volumes/My Share\n',
        ),
        600 * 1024,
      );
    });

    test('unparseable df output is unknown', () {
      expect(parseDfAvailableBytes(''), isNull);
      expect(parseDfAvailableBytes('df: no such file'), isNull);
    });

    test('reads the real free space of a directory', () async {
      final free = await readFreeBytes('/tmp/definitely/not/created');
      expect(free == null || free > 0, isTrue);
    });
  });
}
