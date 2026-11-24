/// Per-import change to resolved capture dates, for fixing a wrong camera
/// clock or time zone. [fixed] replaces every date; otherwise [shift] moves
/// each resolved date by a wall-clock amount.
class CaptureDateAdjustment {
  const CaptureDateAdjustment({this.fixed, this.shift = Duration.zero});

  static const none = CaptureDateAdjustment();

  final DateTime? fixed;
  final Duration shift;

  /// A shift of [hours] and [minutes] forward, or backward when [negative].
  factory CaptureDateAdjustment.shiftBy({
    bool negative = false,
    int hours = 0,
    int minutes = 0,
  }) {
    final shift = Duration(hours: hours, minutes: minutes);
    return CaptureDateAdjustment(shift: negative ? -shift : shift);
  }

  bool get isActive => fixed != null || shift != Duration.zero;

  /// One line for the plan and review UI, or null when nothing is adjusted.
  String? get description {
    final fixed = this.fixed;
    if (fixed != null) return 'Capture date set to ${_format(fixed)}';
    if (shift == Duration.zero) return null;
    final total = shift.inMinutes.abs();
    return 'Capture dates shifted by ${shift.isNegative ? '-' : '+'}'
        '${total ~/ 60} h ${total % 60} min';
  }

  static String _format(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
  }
}

/// The date a file is filed and labelled under: the user's override, else the
/// embedded metadata date (EXIF, CR3), else a date in the file name, else the
/// file's modified time. A shift is applied on top of the last three.
DateTime? resolveCaptureDate({
  DateTime? embedded,
  Iterable<String> fileNames = const [],
  DateTime? modified,
  CaptureDateAdjustment adjustment = CaptureDateAdjustment.none,
}) {
  final fixed = adjustment.fixed;
  if (fixed != null) return fixed;
  final base =
      embedded ??
      fileNames.map(dateFromFileName).whereType<DateTime>().firstOrNull ??
      modified;
  if (base == null || adjustment.shift == Duration.zero) return base;
  // Shift the wall-clock fields so a daylight saving change doesn't skew it.
  return DateTime(
    base.year,
    base.month,
    base.day,
    base.hour,
    base.minute + adjustment.shift.inMinutes,
    base.second,
  );
}

final _compactFileName = RegExp(
  r'(?<!\d)(?:img|vid|dsc)_?(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})(?!\d)',
  caseSensitive: false,
);
final _dashedFileName = RegExp(
  r'(?<!\d)(\d{4})-(\d{2})-(\d{2})[_-](\d{2})-?(\d{2})-?(\d{2})(?!\d)',
);

/// Reads dates such as `IMG_20261017_143000` or `2026-10-17_14-30-00` from a
/// file name. Returns null for impossible dates like month 13.
DateTime? dateFromFileName(String name) {
  final match =
      _compactFileName.firstMatch(name) ?? _dashedFileName.firstMatch(name);
  if (match == null) return null;
  return _validDate([
    for (var index = 1; index <= 6; index++) int.parse(match[index]!),
  ]);
}

/// Parses `YYYY:MM:DD HH:MM:SS`, the format EXIF uses.
DateTime? parseExifDate(String value) {
  final match = RegExp(
    r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(value.trim());
  if (match == null) return null;
  return _validDate([
    for (var index = 1; index <= 6; index++) int.parse(match[index]!),
  ]);
}

DateTime? _validDate(List<int> parts) {
  final date = DateTime(
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
    parts[5],
  );
  if (date.year != parts[0] ||
      date.month != parts[1] ||
      date.day != parts[2] ||
      date.hour != parts[3] ||
      date.minute != parts[4] ||
      date.second != parts[5]) {
    return null;
  }
  return date;
}
