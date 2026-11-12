class GatewayStatus {
  const GatewayStatus({
    required this.device,
    required this.status,
    required this.queueCount,
    required this.lastSequence,
    this.lastBootId,
    this.timeSet = false,
    this.pendingInterval = 0,
    this.packets = 0,
    this.latest,
    this.raw = const {},
  });

  final String device;
  final String status;
  final int queueCount;
  final int lastSequence;
  final int? lastBootId;
  final bool timeSet;
  final int pendingInterval;
  final int packets;
  final GatewayReadingDto? latest;
  final Map<String, dynamic> raw;

  bool get isOnline =>
      status.toLowerCase() == 'online' || queueCount >= 0;

  factory GatewayStatus.fromJson(Map<String, dynamic> json) {
    final latestRaw = json['latest'];
    GatewayReadingDto? latest;
    if (latestRaw is Map) {
      try {
        latest = GatewayReadingDto.fromJson(
          Map<String, dynamic>.from(latestRaw),
        );
      } catch (_) {}
    }
    return GatewayStatus(
      device: (json['device'] ?? json['name'] ?? 'WaterLevel').toString(),
      status: (json['status'] ?? json['state'] ?? 'online').toString(),
      queueCount: _asInt(
            json['records'] ??
                json['queue_count'] ??
                json['queueCount'] ??
                json['pending'] ??
                json['count'],
          ) ??
          0,
      lastSequence: _asInt(
            json['last_sequence'] ?? json['lastSequence'] ?? json['seq'],
          ) ??
          latest?.seq ??
          0,
      lastBootId: _asInt(
            json['last_boot_id'] ?? json['lastBootId'] ?? json['boot_id'],
          ) ??
          latest?.bootId,
      timeSet: json['time_set'] == true || json['timeSet'] == true,
      pendingInterval:
          _asInt(json['pending_interval'] ?? json['pendingInterval']) ?? 0,
      packets: _asInt(json['packets']) ?? 0,
      latest: latest,
      raw: json,
    );
  }
}

class GatewayDataPage {
  const GatewayDataPage({
    required this.records,
    required this.lastId,
    required this.more,
  });

  final List<GatewayReadingDto> records;
  final int lastId;
  final bool more;
}

class GatewayReadingDto {
  const GatewayReadingDto({
    required this.bootId,
    required this.seq,
    this.recordId,
    this.version = 0,
    this.ageSeconds = 0,
    this.measurementTime,
    this.distanceMm,
    this.waterLevelMm,
    this.status = 0,
    this.validSamples = 0,
    this.sendIntervalSeconds = 30,
  });

  /// Node B queue id used by `/data?since=` and `/ack?upto=`.
  final int? recordId;
  final int version;
  final int bootId;
  final int seq;
  final int ageSeconds;
  /// Absolute unix seconds from Node B (`ts`), when available.
  final int? measurementTime;
  final int? distanceMm;
  final int? waterLevelMm;
  final int status;
  final int validSamples;
  final int sendIntervalSeconds;

  String get uniqueKey => '${bootId}_$seq';

  factory GatewayReadingDto.fromJson(Map<String, dynamic> json) {
    final bootId = _asInt(json['boot'] ?? json['boot_id'] ?? json['bootId']);
    // Never fall back to `id` for seq — `id` is the Node B queue cursor.
    final seq = _asInt(json['seq'] ?? json['sequence']);
    if (bootId == null || seq == null) {
      throw FormatException('Reading missing boot/seq: $json');
    }

    final dist = _asNullableMm(
      json['dist'] ?? json['distance_mm'] ?? json['distanceMm'] ?? json['distance'],
    );
    final level = _asNullableMm(
      json['level'] ?? json['water_level_mm'] ?? json['waterLevelMm'],
    );

    return GatewayReadingDto(
      recordId: _asInt(json['id'] ?? json['record_id'] ?? json['recordId']),
      version: _asInt(json['version'] ?? json['ver']) ?? 0,
      bootId: bootId,
      seq: seq,
      ageSeconds:
          _asInt(json['age_seconds'] ?? json['ageSeconds'] ?? json['age']) ?? 0,
      measurementTime: _asInt(json['ts'] ?? json['measurement_time'] ?? json['time']),
      distanceMm: dist,
      waterLevelMm: level,
      status: _asInt(json['status'] ?? json['sensor_status']) ?? 0,
      validSamples:
          _asInt(json['samples'] ?? json['valid_samples'] ?? json['validSamples']) ??
              0,
      sendIntervalSeconds: _asInt(
            json['interval'] ??
                json['send_interval_seconds'] ??
                json['sendIntervalSeconds'],
          ) ??
          30,
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
    this.uptoId,
  });

  final String stationId;
  final List<({int bootId, int seq})> records;
  final int? uptoId;

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
        acked: _asInt(json['acked'] ?? json['deleted'] ?? json['count']) ?? 0,
        status: (json['status'] ?? 'ok').toString(),
      );
}

int? _asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

/// Parse mm values; treat 0xFFFF / negative sentinel as null.
int? _asNullableMm(Object? value) {
  final n = _asInt(value);
  if (n == null) return null;
  if (n < 0 || n == 0xFFFF) return null;
  return n;
}

/// Pull a list of reading maps from common ESP response shapes.
List<Map<String, dynamic>> extractReadingMaps(dynamic data) {
  if (data == null) return const [];
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }
  if (data is Map) {
    final map = Map<String, dynamic>.from(data);
    for (final key in ['records', 'readings', 'data', 'items', 'queue']) {
      final v = map[key];
      if (v is List) {
        return v
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    }
    if (map.containsKey('boot') ||
        map.containsKey('boot_id') ||
        map.containsKey('seq')) {
      return [map];
    }
  }
  return const [];
}
