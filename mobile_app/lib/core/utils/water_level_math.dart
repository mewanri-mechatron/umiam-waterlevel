import 'package:intl/intl.dart';

import '../constants/app_constants.dart';
import 'display_units.dart';

bool _validMm(int? mm) =>
    mm != null && mm != AppConstants.unavailableMm;

/// Calibrated dam elevation (stored as feet×1000 in legacy `*_mm` fields).
///
/// Gap = ultrasonic distance from sensor to water (true millimetres).
///
///   elevation_ft = actual_ft_at_cal + (gap_at_cal_mm − gap_now_mm) / 304.8
///
/// When water rises, gap shrinks, so elevation goes up.
///
/// Example: set 3201.90 ft when gap is 1.50 m (1500 mm);
/// later gap is 1.40 m → +0.328 ft → 3202.23 ft
int? resolveDisplayLevelMm({
  required int? referenceActualMm,
  int? referenceDistanceMm,
  int? currentDistanceMm,
  /// Unused for math (kept so older call sites still compile).
  int? referenceRawLevelMm,
  int? currentRawLevelMm,
  int? fallbackSensorLevelMm,
}) {
  if (referenceActualMm == null) {
    // Not calibrated yet — nothing meaningful to show as RL water level.
    return null;
  }

  if (_validMm(referenceDistanceMm) && _validMm(currentDistanceMm)) {
    final deltaFt =
        (referenceDistanceMm! - currentDistanceMm!) / 304.8;
    return (referenceActualMm + deltaFt * 1000).round();
  }

  return null;
}

/// Snapshot used when the user taps “Use this level” in Setup.
/// [actualWaterLevelFeet] is dam RL in feet AMSL.
({int actualMm, int? rawLevelMm, int? distanceMm}) calibrationSnapshot({
  required double actualWaterLevelFeet,
  int? rawLevelMm,
  int? distanceMm,
}) {
  return (
    actualMm: (actualWaterLevelFeet * 1000).round(),
    rawLevelMm: _validMm(rawLevelMm) ? rawLevelMm : null,
    distanceMm: _validMm(distanceMm) ? distanceMm : null,
  );
}

/// 12-hour clock with am/pm.
String formatReadingTime(int epochSeconds, {bool withSeconds = false}) {
  final pattern =
      withSeconds ? 'dd MMM yyyy h:mm:ss a' : 'dd MMM yyyy h:mm a';
  return DateFormat(pattern).format(
    DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000),
  );
}

String formatReadingTimeShort(int epochSeconds) {
  return DateFormat('dd MMM h:mm a').format(
    DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000),
  );
}

String formatLevelMeters(
  int? waterLevelMm, {
  DisplayLengthUnit unit = DisplayLengthUnit.feet,
}) {
  if (!_validMm(waterLevelMm)) return '—';
  return unit.formatElevation(waterLevelMm);
}

String formatDistanceMeters(
  int? distanceMm, {
  DisplayLengthUnit unit = DisplayLengthUnit.feet,
}) {
  if (!_validMm(distanceMm)) return '—';
  return unit.formatPhysical(distanceMm);
}

/// Seconds → hours label for interval UI (e.g. 1800 → "0.5 h").
String formatIntervalHours(int seconds) {
  final h = seconds / 3600.0;
  if (h == h.roundToDouble()) return '${h.toInt()} h';
  return '${h.toStringAsFixed(h < 1 ? 2 : 1)} h';
}

double? mmToMetres(int? mm) {
  if (!_validMm(mm)) return null;
  return double.parse((mm! / 1000.0).toStringAsFixed(2));
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

/// One reading's time inputs from Node B /data.
class GatewayTimeHint {
  const GatewayTimeHint({
    required this.bootId,
    required this.seq,
    this.recordId,
    this.measurementTime,
    this.ageSeconds = 0,
    this.sendIntervalSeconds = 30,
  });

  final int? recordId;
  final int bootId;
  final int seq;
  final int? measurementTime;
  final int ageSeconds;
  final int sendIntervalSeconds;
}

/// Resolve wall-clock measurement times for a download batch.
///
/// Node B has no battery-backed RTC. After power loss it often stamps every
/// queued row with the same `ts` (the moment `/time` was set / phone synced).
/// When that collapse is detected, rebuild times from seq + send interval,
/// walking backward from the newest sample.
List<int> resolveBatchMeasurementTimes({
  required List<GatewayTimeHint> hints,
  required int receiveEpochSeconds,
}) {
  if (hints.isEmpty) return const [];

  final order = List<int>.generate(hints.length, (i) => i);
  order.sort((a, b) {
    final ai = hints[a].recordId;
    final bi = hints[b].recordId;
    if (ai != null && bi != null && ai != bi) return ai.compareTo(bi);
    final byBoot = hints[a].bootId.compareTo(hints[b].bootId);
    if (byBoot != 0) return byBoot;
    return hints[a].seq.compareTo(hints[b].seq);
  });

  final preferred = List<int?>.filled(hints.length, null);
  for (var i = 0; i < hints.length; i++) {
    final h = hints[i];
    if (h.ageSeconds > 0) {
      preferred[i] = receiveEpochSeconds - h.ageSeconds;
    } else if (h.measurementTime != null && h.measurementTime! > 0) {
      preferred[i] = h.measurementTime;
    }
  }

  final uniquePreferred =
      preferred.whereType<int>().toSet();
  final collapsed = hints.length >= 2 &&
      uniquePreferred.length == 1 &&
      preferred.every((t) => t != null);

  if (!collapsed) {
    return List<int>.generate(hints.length, (i) {
      return preferred[i] ??
          (hints[i].measurementTime != null && hints[i].measurementTime! > 0
              ? hints[i].measurementTime!
              : receiveEpochSeconds);
    });
  }

  // Same ts on every row → treat that ts as the newest sample's time.
  final anchor = uniquePreferred.first;
  final out = List<int>.filled(hints.length, anchor);
  var t = anchor;
  for (var k = order.length - 1; k >= 0; k--) {
    final idx = order[k];
    out[idx] = t;
    if (k == 0) break;
    final newer = hints[order[k]];
    final older = hints[order[k - 1]];
    final interval = newer.sendIntervalSeconds.clamp(10, 3600);
    if (newer.bootId == older.bootId && newer.seq > older.seq) {
      t -= (newer.seq - older.seq) * interval;
    } else {
      t -= interval;
    }
  }
  return out;
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
