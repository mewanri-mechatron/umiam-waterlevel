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
    return '—';
  }
  return '${(waterLevelMm / 1000.0).toStringAsFixed(2)} m';
}

String formatDistanceMeters(int? distanceMm) {
  if (distanceMm == null || distanceMm == AppConstants.unavailableMm) {
    return '—';
  }
  return '${(distanceMm / 1000.0).toStringAsFixed(2)} m';
}

double? mmToMetres(int? mm) {
  if (mm == null || mm == AppConstants.unavailableMm) return null;
  return double.parse((mm / 1000.0).toStringAsFixed(2));
}

String sensorStatusLabel(int status) {
  switch (status) {
    case 0:
      return 'OK';
    case 1:
      return 'Too close (<0.28 m)';
    case 2:
      return 'No echo';
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
