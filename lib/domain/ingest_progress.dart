import 'media.dart';
import 'view_options.dart';

/// Progress of an import: file steps (copies, then Trash moves) and, while
/// copying, bytes, so one huge video doesn't look like one tiny photo.
class IngestProgress {
  const IngestProgress({
    required this.phase,
    required this.done,
    required this.total,
    int? copyTotal,
    this.bytesDone = 0,
    this.bytesTotal = 0,
    this.currentFile,
  }) : copyTotal = copyTotal ?? total;

  static const copyPhase = 'Copying and verifying';

  final String phase;

  /// Finished steps out of [total]; the first [copyTotal] are copies.
  final int done;
  final int total;
  final int copyTotal;
  final int bytesDone;
  final int bytesTotal;
  final String? currentFile;

  /// Overall fraction. Copy steps are weighted by bytes when sizes are known,
  /// so it grows monotonically through the copy and the Trash steps.
  double? get fraction {
    if (total == 0) return null;
    final copied = done < copyTotal ? done : copyTotal;
    final copyShare = bytesTotal > 0
        ? (bytesDone / bytesTotal).clamp(0.0, 1.0) * copyTotal
        : copied.toDouble();
    return ((copyShare + (done - copied)) / total).clamp(0.0, 1.0);
  }

  String get filesLabel =>
      '${done < copyTotal ? done : copyTotal} / $copyTotal files';

  /// `1.2 GB / 4.0 GB`, or null when no sizes are known.
  String? get bytesLabel => bytesTotal == 0
      ? null
      : '${MediaViewOrder.sizeLabel(bytesDone)} / '
            '${MediaViewOrder.sizeLabel(bytesTotal)}';
}

/// Bytes a set of files will occupy; files of unknown size count as zero.
int totalBytes(Iterable<MediaFile> files) =>
    files.fold<int>(0, (total, file) => total + (file.sizeBytes ?? 0));
