import 'package:flutter_test/flutter_test.dart';
import 'package:water_level/core/errors/app_exception.dart';
import 'package:water_level/core/utils/crc16_modbus.dart';
import 'package:water_level/core/utils/payload_decoder.dart';

List<int> buildPayload({
  int version = 0xB4,
  int bootId = 12,
  int seq = 0x0102,
  int age = 30,
  int distance = 1250,
  int water = 3750,
  int status = 0,
  int samples = 3,
  int interval = 30,
}) {
  final bytes = <int>[
    version,
    bootId,
    (seq >> 8) & 0xFF,
    seq & 0xFF,
    (age >> 24) & 0xFF,
    (age >> 16) & 0xFF,
    (age >> 8) & 0xFF,
    age & 0xFF,
    (distance >> 8) & 0xFF,
    distance & 0xFF,
    (water >> 8) & 0xFF,
    water & 0xFF,
    status,
    samples,
    (interval >> 8) & 0xFF,
    interval & 0xFF,
  ];
  return appendCrc16Modbus(bytes);
}

void main() {
  const decoder = WaterLevelPayloadDecoder();

  test('decodes valid 0xB4 payload', () {
    final decoded = decoder.decode(buildPayload());
    expect(decoded.version, 0xB4);
    expect(decoded.bootId, 12);
    expect(decoded.seq, 0x0102);
    expect(decoded.ageSeconds, 30);
    expect(decoded.distanceMm, 1250);
    expect(decoded.waterLevelMm, 3750);
    expect(decoded.status, 0);
    expect(decoded.validSamples, 3);
    expect(decoded.sendIntervalSeconds, 30);
  });

  test('rejects invalid CRC', () {
    final bad = buildPayload();
    bad[16] ^= 0xFF;
    expect(() => decoder.decode(bad), throwsA(isA<ValidationException>()));
  });

  test('rejects wrong version', () {
    expect(
      () => decoder.decode(buildPayload(version: 0x01)),
      throwsA(isA<ValidationException>()),
    );
  });

  test('rejects wrong length', () {
    expect(
      () => decoder.decode([1, 2, 3]),
      throwsA(isA<ValidationException>()),
    );
  });
}
