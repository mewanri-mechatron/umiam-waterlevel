/// CRC16 Modbus (poly 0xA001, init 0xFFFF).
int crc16Modbus(List<int> data) {
  var crc = 0xFFFF;
  for (final byte in data) {
    crc ^= byte & 0xFF;
    for (var i = 0; i < 8; i++) {
      if ((crc & 0x0001) != 0) {
        crc = (crc >> 1) ^ 0xA001;
      } else {
        crc >>= 1;
      }
    }
  }
  return crc & 0xFFFF;
}

/// Append CRC as low-byte-first (wire order used by Node A).
List<int> appendCrc16Modbus(List<int> payloadWithoutCrc) {
  final crc = crc16Modbus(payloadWithoutCrc);
  return [...payloadWithoutCrc, crc & 0xFF, (crc >> 8) & 0xFF];
}

bool verifyCrc16Modbus(List<int> fullPayload) {
  if (fullPayload.length < 3) return false;
  final body = fullPayload.sublist(0, fullPayload.length - 2);
  final expected = crc16Modbus(body);
  final actual =
      (fullPayload[fullPayload.length - 2]) |
      (fullPayload[fullPayload.length - 1] << 8);
  return expected == actual;
}
