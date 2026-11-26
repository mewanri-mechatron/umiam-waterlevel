import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../core/constants/app_constants.dart';

class PhoneStatus {
  const PhoneStatus({
    required this.deviceId,
    required this.name,
    required this.model,
    required this.android,
    required this.appVersion,
    required this.freeStorageMb,
    required this.batteryPct,
    required this.charging,
    required this.batteryUnrestricted,
    required this.notificationsOn,
    required this.exactAlarms,
    required this.locationPermission,
    required this.serviceRunning,
  });

  factory PhoneStatus.fromMap(Map<String, Object?> m) {
    int asInt(Object? v, int fallback) => v is num ? v.toInt() : fallback;
    bool asBool(Object? v, bool fallback) => v is bool ? v : fallback;
    return PhoneStatus(
      deviceId: m['device_id']?.toString() ?? '',
      name: m['name']?.toString() ?? '',
      model: m['model']?.toString() ?? '',
      android: m['android']?.toString() ?? '',
      appVersion: m['app_version']?.toString() ?? '',
      freeStorageMb: asInt(m['free_storage_mb'], -1),
      batteryPct: asInt(m['battery_pct'], -1),
      charging: asBool(m['charging'], false),
      batteryUnrestricted: asBool(m['battery_unrestricted'], true),
      notificationsOn: asBool(m['notifications_on'], true),
      exactAlarms: asBool(m['exact_alarms'], true),
      locationPermission: asBool(m['location_permission'], true),
      serviceRunning: asBool(m['service_running'], true),
    );
  }

  /// Below this SQLite writes (and app updates) start failing.
  static const lowStorageMb = 300;

  final String deviceId;
  final String name;
  final String model;
  final String android;
  final String appVersion;
  final int freeStorageMb;
  final int batteryPct;
  final bool charging;
  final bool batteryUnrestricted;
  final bool notificationsOn;
  final bool exactAlarms;
  final bool locationPermission;
  final bool serviceRunning;

  bool get storageLow => freeStorageMb >= 0 && freeStorageMb < lowStorageMb;

  /// Short code the office can match against the Phones list.
  String get shortId =>
      deviceId.length <= 4 ? deviceId : deviceId.substring(deviceId.length - 4);
}

class NetworkService {
  NetworkService({
    Connectivity? connectivity,
    MethodChannel? wifiChannel,
    EventChannel? wifiEvents,
  }) : _connectivity = connectivity ?? Connectivity(),
       _wifiChannel =
           wifiChannel ?? const MethodChannel('com.waterlevel.app/wifi'),
       _wifiEvents =
           wifiEvents ?? const EventChannel('com.waterlevel.app/wifi_events');

  final Connectivity _connectivity;
  final MethodChannel _wifiChannel;
  final EventChannel _wifiEvents;

  StreamSubscription<dynamic>? _eventSub;
  final _gatewayEvents = StreamController<Map<String, dynamic>>.broadcast();

  /// SoftAP connect / lost events from Android (WifiNetworkSpecifier).
  Stream<Map<String, dynamic>> get onGatewayEvents {
    _ensureEventListen();
    return _gatewayEvents.stream;
  }

  void _ensureEventListen() {
    _eventSub ??= _wifiEvents.receiveBroadcastStream().listen((raw) {
      if (raw is Map) {
        _gatewayEvents.add(raw.map((k, v) => MapEntry(k.toString(), v)));
      }
    });
  }

  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _connectivity.onConnectivityChanged;

  Future<void> requestWifiPermissions() async {
    try {
      await _wifiChannel.invokeMethod<void>('requestWifiPermissions');
    } on MissingPluginException {
      // Ignore on unsupported platforms.
    } on PlatformException {
      // Ignore.
    }
  }

  Future<bool> isWifiEnabled() async {
    try {
      final ok = await _wifiChannel.invokeMethod<bool>('isWifiEnabled');
      return ok ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }

  /// Returns `already_on`, `enabling`, or `prompt` (system WiFi panel opened).
  Future<String> ensureWifiEnabled() async {
    try {
      final result = await _wifiChannel.invokeMethod<String>(
        'ensureWifiEnabled',
      );
      return result ?? 'prompt';
    } on MissingPluginException {
      return 'already_on';
    } on PlatformException catch (e) {
      return e.message ?? 'prompt';
    }
  }

  /// Best-effort SoftAP release so mobile data can reach Firebase.
  Future<bool> pauseWifiForCloudUpload() async {
    try {
      final ok = await _wifiChannel.invokeMethod<bool>(
        'pauseWifiForCloudUpload',
      );
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> resumeWifiAfterCloudUpload() async {
    try {
      final ok = await _wifiChannel.invokeMethod<bool>(
        'resumeWifiAfterCloudUpload',
      );
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<Map<String, dynamic>> wifiDiagnostics() async {
    try {
      final raw = await _wifiChannel.invokeMethod<dynamic>(
        'getWifiDiagnostics',
      );
      if (raw is Map) {
        return raw.map((k, v) => MapEntry(k.toString(), v));
      }
    } on MissingPluginException {
      // Fall through.
    } on PlatformException {
      // Fall through.
    }
    return {};
  }

  /// SoftAP check for the home UI. Strict: WaterLevel SSID / 192.168.4.x only.
  /// The HTTP probe rebinds the whole process to WiFi, so it is opt-in only.
  Future<bool> isOnGatewayFast({bool allowHttpProbe = false}) async {
    try {
      final ok = await _wifiChannel
          .invokeMethod<bool>('isOnGateway')
          .timeout(const Duration(milliseconds: 800));
      if (ok == true) return true;
      if (ok == false) {
        // Native said no — only allow a positive override via SSID/subnet.
      }
    } on MissingPluginException {
      // Fall through.
    } on PlatformException {
      // Fall through.
    } on TimeoutException {
      // Fall through.
    }
    try {
      final diag = await wifiDiagnostics().timeout(
        const Duration(milliseconds: 800),
      );
      final ssid = (diag['ssid'] as String?)?.replaceAll('"', '');
      if (ssid != null &&
          ssid.toLowerCase() == AppConstants.gatewaySsid.toLowerCase()) {
        return true;
      }
      if (diag['gatewaySsidMatch'] == true) return true;
      if (diag['onGatewaySubnet'] == true) return true;
      // Do not use localOnlyWifi alone — many phones mark captive WiFi that way.
    } catch (_) {}

    // HTTP to 192.168.4.1 only as last resort (can false-positive on some LANs).
    if (!allowHttpProbe) return false;
    try {
      return await gatewayHttpReachable().timeout(
        const Duration(milliseconds: 900),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    }
  }

  /// Peek only — never rebinds process traffic (safe for UI status polls).
  Future<bool> peekHasInternet() async {
    try {
      final native = await _wifiChannel.invokeMethod<bool>(
        'hasValidatedInternet',
      );
      if (native == true) return true;
    } on MissingPluginException {
      // Fall through.
    } on PlatformException {
      // Fall through.
    }
    final results = await _connectivity.checkConnectivity();
    return results.contains(ConnectivityResult.mobile) ||
        results.contains(ConnectivityResult.ethernet) ||
        (results.contains(ConnectivityResult.wifi) &&
            !await isOnGatewayFast(allowHttpProbe: false));
  }

  /// Process-wide sync lock shared with the background service and worker.
  /// Returns true when unsupported (tests / non-Android) so sync still runs.
  Future<bool> acquireSyncLease(String owner, Duration ttl) async {
    try {
      final ok = await _wifiChannel
          .invokeMethod<bool>('syncLeaseAcquire', {
            'owner': owner,
            'ttlMs': ttl.inMilliseconds,
          })
          .timeout(const Duration(seconds: 2));
      return ok ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    } on TimeoutException {
      return true;
    }
  }

  Future<void> releaseSyncLease(String owner) async {
    try {
      await _wifiChannel
          .invokeMethod<void>('syncLeaseRelease', {'owner': owner})
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Lease expires on its own.
    }
  }

  /// Ask the native reporter to send this phone's status + logs to the office.
  Future<void> requestCloudReport({bool force = false}) async {
    try {
      await _wifiChannel
          .invokeMethod<void>('cloudReport', {'force': force})
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Next service cycle reports anyway.
    }
  }

  /// Phone identity + settings that affect background sync. Empty if unknown.
  Future<PhoneStatus?> phoneStatus() async {
    try {
      final raw = await _wifiChannel
          .invokeMethod<dynamic>('deviceInfo')
          .timeout(const Duration(seconds: 4));
      if (raw is Map && raw.isNotEmpty) {
        return PhoneStatus.fromMap(
          raw.map((k, v) => MapEntry(k.toString(), v)),
        );
      }
    } catch (_) {}
    return null;
  }

  Future<String?> setPhoneName(String name) async {
    try {
      return await _wifiChannel
          .invokeMethod<String>('setDeviceName', {'name': name})
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  /// [which]: battery, notifications, alarms, location, app.
  Future<void> openPhoneSettings(String which) async {
    try {
      await _wifiChannel
          .invokeMethod<bool>('openPhoneSettings', {'which': which})
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Future<void> markWorkerPullDone() async {
    try {
      await _wifiChannel
          .invokeMethod<void>('markWorkerPullDone')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Service falls back to its own timeout.
    }
  }

  /// May rebind process to LTE for Firebase uploads. Do not call from UI polls.
  Future<bool> hasInternet() async {
    try {
      final native = await _wifiChannel.invokeMethod<bool>(
        'hasValidatedInternet',
      );
      if (native == true) {
        await bindToInternetNetwork();
        return true;
      }
      if (native == false) {
        if (await bindToInternetNetwork()) return true;
      }
    } on MissingPluginException {
      // Background isolate may already be bound.
    } on PlatformException {
      // Fall through.
    }

    final results = await _connectivity.checkConnectivity();
    if (results.contains(ConnectivityResult.none) || results.isEmpty) {
      return false;
    }
    final onGateway = await isOnGatewayFast();
    final hasMobile = results.contains(ConnectivityResult.mobile);
    if (onGateway) {
      if (hasMobile) {
        final bound = await bindToInternetNetwork();
        return bound || hasMobile;
      }
      return false;
    }
    if (results.any(
      (r) =>
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet,
    )) {
      await bindToInternetNetwork();
      return true;
    }
    return false;
  }

  Future<bool> bindToInternetNetwork() async {
    try {
      final ok = await _wifiChannel.invokeMethod<bool>('bindToInternetNetwork');
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// True if SoftAP is up. Prefer [isOnGatewayFast]; HTTP probe is optional.
  Future<bool> isConnectedToGatewayWifi({bool allowHttpProbe = false}) async {
    if (await isOnGatewayFast()) return true;

    try {
      final ssid = await _wifiChannel.invokeMethod<String>('getWifiSsid');
      if (ssid != null &&
          ssid.replaceAll('"', '') == AppConstants.gatewaySsid) {
        return true;
      }
    } on MissingPluginException {
      // Ignore.
    } on PlatformException {
      // Ignore.
    }

    if (!allowHttpProbe) return false;
    return gatewayHttpReachable();
  }

  Future<bool> gatewayHttpReachable() async {
    try {
      await bindToGatewayNetwork();
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 2),
          validateStatus: (_) => true,
        ),
      );
      final res = await dio.get<dynamic>(
        '${AppConstants.gatewayBaseUrl}/status',
      );
      return res.statusCode != null && res.statusCode! < 500;
    } catch (_) {
      return false;
    }
  }

  Map<String, String> get _gatewayWifiArgs => {
    'ssid': AppConstants.gatewaySsid,
    'password': AppConstants.gatewayPassword,
  };

  Future<String> requestGatewayWifiConnection() async {
    _ensureEventListen();
    try {
      final result = await _wifiChannel.invokeMethod<String>(
        'connectToGatewayWifi',
        _gatewayWifiArgs,
      );
      return result ?? 'Follow the system WiFi prompt to join WaterLevel.';
    } on MissingPluginException {
      return 'Open WiFi settings → "${AppConstants.gatewaySsid}" → password ${AppConstants.gatewayPassword}.';
    } on PlatformException catch (e) {
      return e.message ??
          'Unable to start WiFi connection. Connect manually to ${AppConstants.gatewaySsid}.';
    }
  }

  Future<String> suggestGatewayWifi() async {
    try {
      final result = await _wifiChannel.invokeMethod<String>(
        'suggestGatewayWifi',
        _gatewayWifiArgs,
      );
      return result ?? 'WiFi suggestion registered.';
    } on MissingPluginException {
      return 'Open WiFi settings → "${AppConstants.gatewaySsid}" → password ${AppConstants.gatewayPassword}.';
    } on PlatformException catch (e) {
      return e.message ?? 'Unable to register WaterLevel WiFi suggestion.';
    }
  }

  Future<bool> startSiteSyncService() async {
    try {
      final ok = await _wifiChannel.invokeMethod<bool>('startSiteSyncService');
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> stopSiteSyncService() async {
    try {
      final ok = await _wifiChannel.invokeMethod<bool>('stopSiteSyncService');
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> bindToGatewayNetwork() async {
    try {
      final ok = await _wifiChannel.invokeMethod<bool>('bindToGatewayNetwork');
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> clearNetworkBinding() async {
    try {
      await _wifiChannel.invokeMethod<void>('clearNetworkBinding');
    } on MissingPluginException {
      // Ignore on unsupported platforms.
    } on PlatformException {
      // Ignore.
    }
  }

  void dispose() {
    unawaited(_eventSub?.cancel());
    unawaited(_gatewayEvents.close());
  }
}
