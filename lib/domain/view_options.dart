import 'media.dart';

enum MediaSortOrder {
  nameAscending,
  nameDescending,
  captureNewest,
  captureOldest,
  sizeLargest,
  sizeSmallest;

  static const reviewDefault = captureOldest;
}

class MediaDateGroup<T> {
  const MediaDateGroup({required this.label, required this.items});

  final String label;
  final List<T> items;
}

class MediaViewOrder {
  const MediaViewOrder._();

  static List<MediaFile> sortFiles(
    Iterable<MediaFile> files,
    MediaSortOrder order,
  ) => files.toList()..sort((a, b) => compareFiles(a, b, order));

  static List<int> sortReviewItemIndices(
    List<ReviewItem> items,
    MediaSortOrder order,
  ) {
    final indices = List<int>.generate(items.length, (index) => index);
    indices.sort((a, b) => compareReviewItems(items[a], items[b], order));
    return indices;
  }

  static int compareFiles(MediaFile a, MediaFile b, MediaSortOrder order) {
    final primary = switch (order) {
      MediaSortOrder.nameAscending => a.name.compareTo(b.name),
      MediaSortOrder.nameDescending => b.name.compareTo(a.name),
      MediaSortOrder.captureNewest => _compareDates(
        a.captureDate,
        b.captureDate,
        descending: true,
      ),
      MediaSortOrder.captureOldest => _compareDates(
        a.captureDate,
        b.captureDate,
        descending: false,
      ),
      MediaSortOrder.sizeLargest => _compareSizes(
        a.sizeBytes,
        b.sizeBytes,
        descending: true,
      ),
      MediaSortOrder.sizeSmallest => _compareSizes(
        a.sizeBytes,
        b.sizeBytes,
        descending: false,
      ),
    };
    return primary != 0 ? primary : a.path.compareTo(b.path);
  }

  static int compareReviewItems(
    ReviewItem a,
    ReviewItem b,
    MediaSortOrder order,
  ) {
    final primary = switch (order) {
      MediaSortOrder.nameAscending => a.label.compareTo(b.label),
      MediaSortOrder.nameDescending => b.label.compareTo(a.label),
      MediaSortOrder.captureNewest => _compareDates(
        a.captureDate,
        b.captureDate,
        descending: true,
      ),
      MediaSortOrder.captureOldest => _compareDates(
        a.captureDate,
        b.captureDate,
        descending: false,
      ),
      MediaSortOrder.sizeLargest => _compareSizes(
        a.sizeBytes,
        b.sizeBytes,
        descending: true,
      ),
      MediaSortOrder.sizeSmallest => _compareSizes(
        a.sizeBytes,
        b.sizeBytes,
        descending: false,
      ),
    };
    return primary != 0
        ? primary
        : _reviewIdentity(a).compareTo(_reviewIdentity(b));
  }

  static List<MediaDateGroup<T>> groupByCaptureDate<T>(
    Iterable<T> items,
    DateTime? Function(T item) dateOf, {
    bool newestFirst = true,
  }) {
    final groups = <String, List<T>>{};
    final dates = <String, DateTime>{};
    for (final item in items) {
      final date = dateOf(item);
      final key = date == null ? '' : _dateKey(date);
      groups.putIfAbsent(key, () => []).add(item);
      if (date != null) dates.putIfAbsent(key, () => date);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty) return b.isEmpty ? 0 : 1;
        if (b.isEmpty) return -1;
        return newestFirst
            ? dates[b]!.compareTo(dates[a]!)
            : dates[a]!.compareTo(dates[b]!);
      });
    return [
      for (final key in keys)
        MediaDateGroup(
          label: key.isEmpty ? 'Unknown date' : key,
          items: groups[key]!,
        ),
    ];
  }

  static int _compareDates(
    DateTime? a,
    DateTime? b, {
    required bool descending,
  }) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    final result = a.compareTo(b);
    return descending ? -result : result;
  }

  static int _compareSizes(int? a, int? b, {required bool descending}) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    final result = a.compareTo(b);
    return descending ? -result : result;
  }

  static String _reviewIdentity(ReviewItem item) =>
      item.files.map((file) => file.path).join('|');

  static String captureDateLabel(DateTime? date) {
    if (date == null) return 'Unknown date';
    return '${_dateKey(date)} ${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  static String sizeLabel(int? bytes) {
    if (bytes == null) return 'Unknown size';
    const kilobyte = 1024;
    const megabyte = 1024 * kilobyte;
    const gigabyte = 1024 * megabyte;
    if (bytes < kilobyte) return '$bytes B';
    if (bytes < megabyte) return '${(bytes / kilobyte).toStringAsFixed(1)} KB';
    if (bytes < gigabyte) return '${(bytes / megabyte).toStringAsFixed(1)} MB';
    return '${(bytes / gigabyte).toStringAsFixed(1)} GB';
  }

  static String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
