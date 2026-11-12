import 'package:flutter_test/flutter_test.dart';
import 'package:water_level/core/utils/water_level_math.dart';

void main() {
  test('measurement time subtracts age', () {
    final receive = DateTime.fromMillisecondsSinceEpoch(1_790_000_030 * 1000);
    final measured = measurementTimeFromAge(receiveTime: receive, ageSeconds: 30);
    expect(measured.millisecondsSinceEpoch ~/ 1000, 1_790_000_000);
  });

  test('water level requires mount height', () {
    expect(
      calculateWaterLevelMm(mountHeightMm: null, distanceMm: 1000),
      isNull,
    );
  });

  test('water level rejects negatives', () {
    expect(
      calculateWaterLevelMm(mountHeightMm: 1000, distanceMm: 1500),
      isNull,
    );
  });

  test('water level calculates correctly', () {
    expect(
      calculateWaterLevelMm(mountHeightMm: 5000, distanceMm: 1250),
      3750,
    );
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
    expect(
      compareReadingRecency(
        aMeasurementTime: 100,
        aBootId: 2,
        aSeq: 1,
        bMeasurementTime: 100,
        bBootId: 1,
        bSeq: 99,
      ),
      greaterThan(0),
    );
  });
}
