import 'capture_date.dart';

/// Choices made for one import. They are never saved as defaults.
class ImportOptions {
  const ImportOptions({
    this.dateAdjustment = CaptureDateAdjustment.none,
    this.shoot = '',
  });

  static const none = ImportOptions();

  final CaptureDateAdjustment dateAdjustment;

  /// Value of the `{shoot}` template token; empty when no shoot is named.
  final String shoot;

  bool get isActive => dateAdjustment.isActive || shoot.trim().isNotEmpty;
}
