class GatewayStatus {
  const GatewayStatus({
    required this.device,
    required this.status,
    required this.queueCount,
    required this.lastSequence,
    this.lastBootId,
  });

  final String device;
  final String status;
  final int queueCount;
  final int lastSequence;
  final int? lastBootId;

  bool get isOnline => status.toLowerCase() == 'online';

  factory GatewayStatus.fromJson(Map<String, dynamic> json) => GatewayStatus(
        device: json['device'] as String? ?? 'WaterLevel',
        status: json['status'] as String? ?? 'unknown',
        queueCount: (json['queue_count'] as num?)?.toInt() ?? 0,
        lastSequence: (json['last_sequence'] as num?)?.toInt() ?? 0,
        lastBootId: (json['last_boot_id'] as num?)?.toInt(),
      );
}

class GatewayReadingDto {
  const GatewayReadingDto({
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

  factory GatewayReadingDto.fromJson(Map<String, dynamic> json) {
    return GatewayReadingDto(
      version: (json['version'] as num?)?.toInt() ?? 0,
      bootId: (json['boot_id'] as num).toInt(),
      seq: (json['seq'] as num).toInt(),
      ageSeconds: (json['age_seconds'] as num).toInt(),
      distanceMm: (json['distance_mm'] as num).toInt(),
      waterLevelMm: (json['water_level_mm'] as num).toInt(),
      status: (json['status'] as num).toInt(),
      validSamples: (json['valid_samples'] as num).toInt(),
      sendIntervalSeconds: (json['send_interval_seconds'] as num).toInt(),
    );
  }

  Map<String, dynamic> toAckJson() => {
        'boot_id': bootId,
        'seq': seq,
      };
}

class AckRequest {
  const AckRequest({
    required this.stationId,
    required this.records,
  });

  final String stationId;
  final List<({int bootId, int seq})> records;

  Map<String, dynamic> toJson() => {
        'station_id': stationId,
        'records': records
            .map((r) => {'boot_id': r.bootId, 'seq': r.seq})
            .toList(),
      };
}

class AckResponse {
  const AckResponse({required this.acked, required this.status});

  final int acked;
  final String status;

  factory AckResponse.fromJson(Map<String, dynamic> json) => AckResponse(
        acked: (json['acked'] as num?)?.toInt() ?? 0,
        status: json['status'] as String? ?? 'ok',
      );
}
