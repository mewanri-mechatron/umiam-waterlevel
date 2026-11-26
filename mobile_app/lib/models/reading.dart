import '../core/constants/app_constants.dart';
import '../core/utils/water_level_math.dart';

class Reading {
  const Reading({
    this.id,
    required this.stationId,
    required this.bootId,
    required this.seq,
    required this.measurementTime,
    required this.receivedTime,
    required this.ageSeconds,
    this.distanceMm,
    this.waterLevelMm,
    required this.status,
    required this.validSamples,
    required this.sendIntervalSeconds,
    this.firebaseUploaded = false,
    required this.createdAt,
    this.isSimulated = false,
    this.gatewayRecordId,
  });

  final int? id;
  final String stationId;
  final int bootId;
  final int seq;
  final int measurementTime;
  final int receivedTime;
  final int ageSeconds;
  final int? distanceMm;
  final int? waterLevelMm;
  final int status;
  final int validSamples;
  final int sendIntervalSeconds;
  final bool firebaseUploaded;
  final int createdAt;
  final bool isSimulated;

  /// Node B queue id (`/data` / `/ack?upto=`). Kept until the reading is in
  /// the cloud so the ESP is never told to delete an unsent reading.
  final int? gatewayRecordId;

  String get identityKey => '${stationId}_${bootId}_$seq';
  String get firebaseKey => '${bootId}_$seq';

  bool get hasValidDistance =>
      distanceMm != null && distanceMm != AppConstants.unavailableMm;

  bool get hasValidWaterLevel =>
      waterLevelMm != null && waterLevelMm != AppConstants.unavailableMm;

  Reading copyWith({
    int? id,
    int? waterLevelMm,
    bool? firebaseUploaded,
    int? gatewayRecordId,
    bool clearWaterLevel = false,
  }) {
    return Reading(
      id: id ?? this.id,
      stationId: stationId,
      bootId: bootId,
      seq: seq,
      measurementTime: measurementTime,
      receivedTime: receivedTime,
      ageSeconds: ageSeconds,
      distanceMm: distanceMm,
      waterLevelMm:
          clearWaterLevel ? null : (waterLevelMm ?? this.waterLevelMm),
      status: status,
      validSamples: validSamples,
      sendIntervalSeconds: sendIntervalSeconds,
      firebaseUploaded: firebaseUploaded ?? this.firebaseUploaded,
      createdAt: createdAt,
      isSimulated: isSimulated,
      gatewayRecordId: gatewayRecordId ?? this.gatewayRecordId,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'station_id': stationId,
        'boot_id': bootId,
        'seq': seq,
        'measurement_time': measurementTime,
        'received_time': receivedTime,
        'age_seconds': ageSeconds,
        'distance_mm': distanceMm,
        'water_level_mm': waterLevelMm,
        'status': status,
        'valid_samples': validSamples,
        'send_interval_seconds': sendIntervalSeconds,
        'firebase_uploaded': firebaseUploaded ? 1 : 0,
        'created_at': createdAt,
        'is_simulated': isSimulated ? 1 : 0,
        if (gatewayRecordId != null) 'gateway_record_id': gatewayRecordId,
      };

  factory Reading.fromMap(Map<String, Object?> map) => Reading(
        id: map['id'] as int?,
        stationId: map['station_id']! as String,
        bootId: map['boot_id']! as int,
        seq: map['seq']! as int,
        measurementTime: map['measurement_time']! as int,
        receivedTime: map['received_time']! as int,
        ageSeconds: map['age_seconds']! as int,
        distanceMm: map['distance_mm'] as int?,
        waterLevelMm: map['water_level_mm'] as int?,
        status: map['status']! as int,
        validSamples: map['valid_samples']! as int,
        sendIntervalSeconds: map['send_interval_seconds']! as int,
        firebaseUploaded: (map['firebase_uploaded'] as int? ?? 0) == 1,
        createdAt: map['created_at']! as int,
        isSimulated: (map['is_simulated'] as int? ?? 0) == 1,
        gatewayRecordId: map['gateway_record_id'] as int?,
      );

  /// Rebuild a local reading from an RTDB node written by [toFirebaseMap].
  /// Marks as already uploaded so restore does not re-push the same keys.
  factory Reading.fromFirebaseMap({
    required String stationId,
    required Map<Object?, Object?> map,
    required int createdAt,
  }) {
    final bootId = (map['boot_id'] as num?)?.toInt() ?? 0;
    final seq = (map['seq'] as num?)?.toInt() ?? 0;
    final measurementTime = (map['measurement_time'] as num?)?.toInt() ?? 0;
    final receivedTime = (map['received_time'] as num?)?.toInt() ??
        measurementTime;
    final ageSeconds = (map['age_seconds'] as num?)?.toInt() ?? 0;
    final distanceMm = (map['distance_mm'] as num?)?.toInt();
    // Prefer true sensor raw level; older uploads may only have display level.
    final sensorLevel = (map['sensor_level_mm'] as num?)?.toInt() ??
        (map['water_level_mm'] as num?)?.toInt();
    return Reading(
      stationId: stationId,
      bootId: bootId,
      seq: seq,
      measurementTime: measurementTime,
      receivedTime: receivedTime,
      ageSeconds: ageSeconds,
      distanceMm: distanceMm,
      waterLevelMm: sensorLevel,
      status: (map['status'] as num?)?.toInt() ?? 0,
      validSamples: (map['valid_samples'] as num?)?.toInt() ?? 0,
      sendIntervalSeconds:
          (map['send_interval_seconds'] as num?)?.toInt() ?? 0,
      firebaseUploaded: true,
      createdAt: createdAt,
      isSimulated: false,
    );
  }

  Map<String, Object?> toFirebaseMap({
    required int uploadedAt,
    int? calibActualMm,
    int? calibRawLevelMm,
    int? calibDistanceMm,
  }) {
    final map = <String, Object?>{
      'boot_id': bootId,
      'seq': seq,
      'measurement_time': measurementTime,
      'received_time': receivedTime,
      'age_seconds': ageSeconds,
      'status': status,
      'valid_samples': validSamples,
      'send_interval_seconds': sendIntervalSeconds,
      'uploaded_at': uploadedAt,
    };
    // Omit nulls — RTDB treats null as delete.
    if (distanceMm != null && distanceMm != AppConstants.unavailableMm) {
      map['distance_mm'] = distanceMm;
      map['distance_m'] =
          double.parse((distanceMm! / 1000.0).toStringAsFixed(2));
    }
    // Sensor raw level from Node B (unchanged).
    if (waterLevelMm != null && waterLevelMm != AppConstants.unavailableMm) {
      map['sensor_level_mm'] = waterLevelMm;
      map['sensor_level_m'] =
          double.parse((waterLevelMm! / 1000.0).toStringAsFixed(2));
    }
    final display = resolveDisplayLevelMm(
      referenceActualMm: calibActualMm,
      referenceDistanceMm: calibDistanceMm,
      currentDistanceMm: distanceMm,
    );
    if (display != null) {
      map['water_level_mm'] = display;
      map['water_level_m'] =
          double.parse((display / 1000.0).toStringAsFixed(2));
    }
    return map;
  }
}
