import 'package:flutter_test/flutter_test.dart';
import 'package:water_level/core/utils/crc16_modbus.dart';

void main() {
  test('append and verify round-trip', () {
    final body = List<int>.generate(16, (i) => i);
    final full = appendCrc16Modbus(body);
    expect(full.length, 18);
    expect(verifyCrc16Modbus(full), isTrue);
    full[5] ^= 0x01;
    expect(verifyCrc16Modbus(full), isFalse);
  });
}
