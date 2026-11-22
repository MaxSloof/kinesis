import 'package:path/path.dart' as path;

const unknownCamera = 'Unknown camera';

/// Characters that are separators or invalid in file names on some platform.
final _unsafeCharacters = RegExp(r'[\x00-\x1f/\\:*?"<>|]');
const _separators = r' \-_.,';

/// Turns free text (a shoot name, a camera model) into one safe folder name:
/// unsafe characters become `-`, whitespace is collapsed and leading or
/// trailing dots, dashes and spaces are dropped, so the result can never be
/// `..` or start with a leftover separator.
String sanitizePathComponent(String value) => value
    .replaceAll(_unsafeCharacters, '-')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'^[.\- ]+|[.\- ]+$'), '');

/// `Make Model` from EXIF without repeating the make, which many cameras also
/// put at the start of the model (`Canon` + `Canon EOS R5`).
String? cameraName(String? make, String? model) {
  final cleanMake = make?.replaceAll(RegExp(r'[\x00\s]+'), ' ').trim() ?? '';
  final cleanModel = model?.replaceAll(RegExp(r'[\x00\s]+'), ' ').trim() ?? '';
  if (cleanModel.isEmpty && cleanMake.isEmpty) return null;
  if (cleanMake.isEmpty) return cleanModel;
  if (cleanModel.isEmpty) return cleanMake;
  final firstWord = cleanMake.split(' ').first.toLowerCase();
  final modelWords = cleanModel.toLowerCase().split(' ');
  return modelWords.contains(firstWord) ? cleanModel : '$cleanMake $cleanModel';
}

/// Expands the tokens in a destination [template].
///
/// `{shoot}` is optional: when [shoot] is empty the token is removed together
/// with the separators (space, `-`, `_`, `.`, `,`) that follow it, separators
/// left dangling at the end of that folder name are trimmed, and a folder that
/// ends up empty is dropped, so `{year}/{shoot} - {day}` becomes `2026/17`
/// rather than `2026/ - 17` and `{year}/{shoot}/{day}` has no `//`.
String expandDestinationTemplate(
  String template,
  DateTime date,
  String name,
  String sourceFolder, {
  String shoot = '',
  String? camera,
}) {
  final cleanShoot = sanitizePathComponent(shoot);
  final segments = <String>[];
  for (var segment in template.split('/')) {
    if (segment.contains('{shoot}') && cleanShoot.isEmpty) {
      segment = segment
          .replaceAll(RegExp('\\{shoot\\}[$_separators]*'), '')
          .replaceAll(RegExp('[$_separators]+\$'), '');
      if (segment.isEmpty) continue;
    }
    segments.add(segment);
  }
  final cleanCamera = sanitizePathComponent(camera ?? '');
  return segments
      .join('/')
      .replaceAll('{year}', date.year.toString())
      .replaceAll('{month}', date.month.toString().padLeft(2, '0'))
      .replaceAll('{day}', date.day.toString().padLeft(2, '0'))
      .replaceAll('{originalName}', name)
      .replaceAll('{sourceFolder}', sourceFolder)
      .replaceAll('{shoot}', cleanShoot)
      .replaceAll('{camera}', cleanCamera.isEmpty ? unknownCamera : cleanCamera)
      .replaceAll(
        '{ext}',
        path.extension(name).replaceFirst('.', '').toLowerCase(),
      );
}
