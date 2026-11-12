import '../constants/app_constants.dart';
import '../errors/app_exception.dart';
import 'crc16_modbus.dart';

class DecodedPayload {
  const DecodedPayload({
    required this.version,
    required this.bootId,
    required this.seq,
    required this.ageSeconds,
    required this.distanceMm,
    required this.waterLevelMm,
    required this.status,
    required this.validSamples,
    required this.sendIntervalSeconds,
  });

  final int version;
  final int bootId;
  final int seq;
  final int ageSeconds;
  final int distanceMm;
  final int waterLevelMm;
  final int status;
  final int validSamples;
  final int sendIntervalSeconds;
}

class WaterLevelPayloadDecoder {
  const WaterLevelPayloadDecoder();

  DecodedPayload decode(List<int> bytes) {
    if (bytes.length != 18) {
      throw ValidationException('Payload must be 18 bytes, got ${bytes.length}');
    }
    if (!verifyCrc16Modbus(bytes)) {
      throw ValidationException('CRC16 Modbus check failed');
    }
    if (bytes[0] != AppConstants.payloadVersion) {
      throw ValidationException(
        'Unsupported payload version 0x${bytes[0].toRadixString(16)}',
      );
    }

    final seq = (bytes[2] << 8) | bytes[3];
    final age = (bytes[4] << 24) |
        (bytes[5] << 16) |
        (bytes[6] << 8) |
        bytes[7];
    final distance = (bytes[8] << 8) | bytes[9];
    final water = (bytes[10] << 8) | bytes[11];
    final interval = (bytes[14] << 8) | bytes[15];

    return DecodedPayload(
      version: bytes[0],
      bootId: bytes[1],
      seq: seq,
      ageSeconds: age,
      distanceMm: distance,
      waterLevelMm: water,
      status: bytes[12],
      validSamples: bytes[13],
      sendIntervalSeconds: interval,
    );
  }
}
