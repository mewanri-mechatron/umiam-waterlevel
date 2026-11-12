import '../constants/app_constants.dart';

int? calculateWaterLevelMm({
  required int? mountHeightMm,
  required int? distanceMm,
}) {
  if (mountHeightMm == null || distanceMm == null) return null;
  if (distanceMm == AppConstants.unavailableMm) return null;
  final level = mountHeightMm - distanceMm;
  if (level < 0) return null;
  return level;
}

String formatLevelMeters(int? waterLevelMm) {
  if (waterLevelMm == null || waterLevelMm == AppConstants.unavailableMm) {
    return 'Unavailable';
  }
  final metres = waterLevelMm / 1000.0;
  final cm = waterLevelMm / 10.0;
  return '${metres.toStringAsFixed(2)} m (${cm.toStringAsFixed(0)} cm)';
}

String sensorStatusLabel(int status) {
  switch (status) {
    case 0:
      return 'OK';
    case 1:
      return 'Too close / blind zone';
    case 2:
      return 'No echo / out of range';
    case 3:
      return 'Sensor not responding';
    default:
      return 'Unknown ($status)';
  }
}

DateTime measurementTimeFromAge({
  required DateTime receiveTime,
  required int ageSeconds,
}) {
  return receiveTime.subtract(Duration(seconds: ageSeconds));
}

int compareReadingRecency({
  required int aMeasurementTime,
  required int aBootId,
  required int aSeq,
  required int bMeasurementTime,
  required int bBootId,
  required int bSeq,
}) {
  final byTime = aMeasurementTime.compareTo(bMeasurementTime);
  if (byTime != 0) return byTime;
  final byBoot = aBootId.compareTo(bBootId);
  if (byBoot != 0) return byBoot;
  return aSeq.compareTo(bSeq);
}
