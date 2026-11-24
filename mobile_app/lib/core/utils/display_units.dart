/// Display unit for lengths.
///
/// Dam elevation (calib / water level) is stored as **feet × 1000** in the
/// legacy `*_mm` fields. Sensor raw gap is true millimetres.
enum DisplayLengthUnit {
  feet,
  metres,
  centimetres,
  millimetres,
}

extension DisplayLengthUnitX on DisplayLengthUnit {
  String get label => switch (this) {
        DisplayLengthUnit.feet => 'ft',
        DisplayLengthUnit.metres => 'm',
        DisplayLengthUnit.centimetres => 'cm',
        DisplayLengthUnit.millimetres => 'mm',
      };

  String get longLabel => switch (this) {
        DisplayLengthUnit.feet => 'Feet',
        DisplayLengthUnit.metres => 'Metres',
        DisplayLengthUnit.centimetres => 'Centimetres',
        DisplayLengthUnit.millimetres => 'Millimetres',
      };

  String get prefsValue => name;

  static const double ftPerM = 3.28084;

  static DisplayLengthUnit fromPrefs(String? value) {
    return DisplayLengthUnit.values.firstWhere(
      (u) => u.name == value,
      orElse: () => DisplayLengthUnit.feet,
    );
  }

  int get fractionDigits => switch (this) {
        DisplayLengthUnit.feet => 2,
        DisplayLengthUnit.metres => 2,
        DisplayLengthUnit.centimetres => 1,
        DisplayLengthUnit.millimetres => 0,
      };

  /// Elevation stored as feet×1000 → this display unit.
  double fromElevationStored(num stored) {
    final feet = stored / 1000.0;
    return switch (this) {
      DisplayLengthUnit.feet => feet,
      DisplayLengthUnit.metres => feet / ftPerM,
      DisplayLengthUnit.centimetres => (feet / ftPerM) * 100,
      DisplayLengthUnit.millimetres => (feet / ftPerM) * 1000,
    };
  }

  /// True sensor millimetres (gap / raw distance) → this display unit.
  double fromPhysicalMm(num mm) => switch (this) {
        DisplayLengthUnit.feet => mm / 304.8,
        DisplayLengthUnit.metres => mm / 1000.0,
        DisplayLengthUnit.centimetres => mm / 10.0,
        DisplayLengthUnit.millimetres => mm.toDouble(),
      };

  /// @Deprecated — prefer [fromElevationStored] or [fromPhysicalMm].
  double fromMm(num mm) => fromElevationStored(mm);

  String formatElevation(int? stored, {bool withUnit = true}) {
    if (stored == null || stored == 0xFFFF) return '—';
    final text = fromElevationStored(stored).toStringAsFixed(fractionDigits);
    return withUnit ? '$text $label' : text;
  }

  String formatPhysical(int? mm, {bool withUnit = true}) {
    if (mm == null || mm == 0xFFFF) return '—';
    final text = fromPhysicalMm(mm).toStringAsFixed(fractionDigits);
    return withUnit ? '$text $label' : text;
  }

  /// Alias used by older call sites for elevation.
  String formatMm(int? mm, {bool withUnit = true}) =>
      formatElevation(mm, withUnit: withUnit);
}
