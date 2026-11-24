import 'package:flutter_test/flutter_test.dart';
import 'package:water_level/core/utils/display_units.dart';
import 'package:water_level/core/utils/water_level_math.dart';

void main() {
  test('collapsed Node B timestamps are rebuilt from seq + interval', () {
    const sharedTs = 1_790_000_000;
    final times = resolveBatchMeasurementTimes(
      hints: const [
        GatewayTimeHint(
          recordId: 1,
          bootId: 5,
          seq: 10,
          measurementTime: sharedTs,
          sendIntervalSeconds: 30,
        ),
        GatewayTimeHint(
          recordId: 2,
          bootId: 5,
          seq: 11,
          measurementTime: sharedTs,
          sendIntervalSeconds: 30,
        ),
        GatewayTimeHint(
          recordId: 3,
          bootId: 5,
          seq: 12,
          measurementTime: sharedTs,
          sendIntervalSeconds: 30,
        ),
      ],
      receiveEpochSeconds: sharedTs + 5,
    );
    expect(times, [sharedTs - 60, sharedTs - 30, sharedTs]);
  });

  test('distinct timestamps are kept', () {
    final times = resolveBatchMeasurementTimes(
      hints: const [
        GatewayTimeHint(
          bootId: 1,
          seq: 1,
          measurementTime: 100,
          sendIntervalSeconds: 30,
        ),
        GatewayTimeHint(
          bootId: 1,
          seq: 2,
          measurementTime: 160,
          sendIntervalSeconds: 30,
        ),
      ],
      receiveEpochSeconds: 200,
    );
    expect(times, [100, 160]);
  });

  test('measurement time subtracts age', () {
    final receive = DateTime.fromMillisecondsSinceEpoch(1_790_000_030 * 1000);
    final measured = measurementTimeFromAge(receiveTime: receive, ageSeconds: 30);
    expect(measured.millisecondsSinceEpoch ~/ 1000, 1_790_000_000);
  });

  test('calibrated elevation from actual ft + gap change', () {
    // Actual 3201.90 ft at gap 1.50 m; later gap 1.40 m → +0.328 ft → 3202.228 ft
    expect(
      resolveDisplayLevelMm(
        referenceActualMm: 3201900,
        referenceDistanceMm: 1500,
        currentDistanceMm: 1400,
      ),
      3202228,
    );
  });

  test('without calibration shows nothing', () {
    expect(
      resolveDisplayLevelMm(
        referenceActualMm: null,
        currentDistanceMm: 1400,
      ),
      isNull,
    );
  });

  test('display units: elevation stored as feet×1000', () {
    expect(
      DisplayLengthUnit.feet.fromElevationStored(3201900),
      closeTo(3201.9, 0.001),
    );
    expect(
      DisplayLengthUnit.metres.fromElevationStored(3201900),
      closeTo(3201.9 / DisplayLengthUnitX.ftPerM, 0.01),
    );
    expect(DisplayLengthUnit.feet.formatElevation(3201900), '3201.90 ft');
  });

  test('display units: physical gap in true millimetres', () {
    expect(DisplayLengthUnit.metres.fromPhysicalMm(1500), 1.5);
    expect(DisplayLengthUnit.centimetres.fromPhysicalMm(1500), 150.0);
    expect(DisplayLengthUnit.millimetres.fromPhysicalMm(1500), 1500.0);
    expect(DisplayLengthUnit.feet.fromPhysicalMm(3048), closeTo(10.0, 0.001));
    expect(DisplayLengthUnit.metres.formatPhysical(1500), '1.50 m');
    expect(DisplayLengthUnit.feet.formatPhysical(1524), '5.00 ft');
  });

  test('interval hours formatting', () {
    expect(formatIntervalHours(1800), '0.50 h');
    expect(formatIntervalHours(3600), '1 h');
  });

  test('recency ordering prefers newer measurement then boot then seq', () {
    expect(
      compareReadingRecency(
        aMeasurementTime: 100,
        aBootId: 1,
        aSeq: 1,
        bMeasurementTime: 90,
        bBootId: 9,
        bSeq: 9,
      ),
      greaterThan(0),
    );
  });
}
