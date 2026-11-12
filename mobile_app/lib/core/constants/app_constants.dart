class AppConstants {
  static const String appName = 'WaterLevel';
  static const String defaultStationId = 'station_001';
  static const String defaultStationName = 'Umiam Dam';
  static const String gatewaySsid = 'WaterLevel';
  static const String gatewayIp = '192.168.4.1';
  static const String gatewayBaseUrl = 'http://192.168.4.1';
  static const int unavailableMm = 0xFFFF;
  static const int payloadVersion = 0xB4;
  static const String prefsMountHeight = 'mount_height_mm';
  static const String prefsUseMockGateway = 'use_mock_gateway';
  static const String prefsStationId = 'station_id';
  static const String firebaseDatabaseUrl =
      'https://agri-db-fa27f-default-rtdb.asia-southeast1.firebasedatabase.app';
  static const String syncWorkName = 'waterlevel_firebase_sync';
  static const String siteSyncWorkName = 'waterlevel_site_sync';
  static const String prefsSiteSyncEnabled = 'site_sync_enabled';
}
