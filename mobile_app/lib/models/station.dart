class Station {
  const Station({
    required this.id,
    required this.name,
    required this.gatewayIp,
    required this.wifiSsid,
    this.mountHeightMm,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String gatewayIp;
  final String wifiSsid;
  final int? mountHeightMm;
  final int createdAt;
  final int updatedAt;

  Station copyWith({
    String? name,
    String? gatewayIp,
    String? wifiSsid,
    int? mountHeightMm,
    bool clearMountHeight = false,
    int? updatedAt,
  }) {
    return Station(
      id: id,
      name: name ?? this.name,
      gatewayIp: gatewayIp ?? this.gatewayIp,
      wifiSsid: wifiSsid ?? this.wifiSsid,
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
        'mount_height_mm': mountHeightMm,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Station.fromMap(Map<String, Object?> map) => Station(
        id: map['id']! as String,
        name: map['name']! as String,
        gatewayIp: map['gateway_ip']! as String,
        wifiSsid: map['wifi_ssid']! as String,
        mountHeightMm: map['mount_height_mm'] as int?,
        createdAt: map['created_at']! as int,
        updatedAt: map['updated_at']! as int,
      );
}
