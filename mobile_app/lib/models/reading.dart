import '../core/constants/app_constants.dart';

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
      );

  Map<String, Object?> toFirebaseMap({required int uploadedAt}) {
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
    if (waterLevelMm != null && waterLevelMm != AppConstants.unavailableMm) {
      map['water_level_mm'] = waterLevelMm;
      map['water_level_m'] =
          double.parse((waterLevelMm! / 1000.0).toStringAsFixed(2));
    }
    return map;
  }
}
