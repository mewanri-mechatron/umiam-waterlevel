class Station {
  const Station({
    required this.id,
    required this.name,
    required this.gatewayIp,
    required this.wifiSsid,
    this.calibActualMm,
    this.calibRawLevelMm,
    this.calibDistanceMm,
    /// Kept for older DB rows / cloud; not used for level math.
    this.mountHeightMm,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String gatewayIp;
  final String wifiSsid;

  /// Real gauge water level (mm) at calibration time.
  final int? calibActualMm;

  /// Sensor raw level (mm) at calibration time.
  final int? calibRawLevelMm;

  /// Sensor distance / air gap (mm) at calibration time (fallback).
  final int? calibDistanceMm;

  final int? mountHeightMm;
  final int createdAt;
  final int updatedAt;

  bool get hasCalibration => calibActualMm != null;

  Station copyWith({
    String? name,
    String? gatewayIp,
    String? wifiSsid,
    int? calibActualMm,
    int? calibRawLevelMm,
    int? calibDistanceMm,
    bool clearCalibration = false,
    int? mountHeightMm,
    bool clearMountHeight = false,
    int? updatedAt,
  }) {
    return Station(
      id: id,
      name: name ?? this.name,
      gatewayIp: gatewayIp ?? this.gatewayIp,
      wifiSsid: wifiSsid ?? this.wifiSsid,
      calibActualMm:
          clearCalibration ? null : (calibActualMm ?? this.calibActualMm),
      calibRawLevelMm:
          clearCalibration ? null : (calibRawLevelMm ?? this.calibRawLevelMm),
      calibDistanceMm:
          clearCalibration ? null : (calibDistanceMm ?? this.calibDistanceMm),
      mountHeightMm:
          clearMountHeight ? null : (mountHeightMm ?? this.mountHeightMm),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'gateway_ip': gatewayIp,
        'wifi_ssid': wifiSsid,
        'calib_actual_mm': calibActualMm,
        'calib_raw_level_mm': calibRawLevelMm,
        'calib_distance_mm': calibDistanceMm,
        'mount_height_mm': mountHeightMm,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Station.fromMap(Map<String, Object?> map) => Station(
        id: map['id']! as String,
        name: map['name']! as String,
        gatewayIp: map['gateway_ip']! as String,
        wifiSsid: map['wifi_ssid']! as String,
        calibActualMm: map['calib_actual_mm'] as int?,
        calibRawLevelMm: map['calib_raw_level_mm'] as int?,
        calibDistanceMm: map['calib_distance_mm'] as int?,
        mountHeightMm: map['mount_height_mm'] as int?,
        createdAt: map['created_at']! as int,
        updatedAt: map['updated_at']! as int,
      );
}
