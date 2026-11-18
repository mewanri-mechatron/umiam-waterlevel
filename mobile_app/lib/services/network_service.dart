import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../core/constants/app_constants.dart';

class NetworkService {
  NetworkService({
    Connectivity? connectivity,
    MethodChannel? wifiChannel,
    EventChannel? wifiEvents,
  })  : _connectivity = connectivity ?? Connectivity(),
        _wifiChannel = wifiChannel ??
            const MethodChannel('com.waterlevel.app/wifi'),
        _wifiEvents = wifiEvents ??
            const EventChannel('com.waterlevel.app/wifi_events');

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
      final result = await _wifiChannel.invokeMethod<String>('ensureWifiEnabled');
      return result ?? 'prompt';
    } on MissingPluginException {
      return 'already_on';
    } on PlatformException catch (e) {
      return e.message ?? 'prompt';
    }
  }

  Future<Map<String, dynamic>> wifiDiagnostics() async {
    try {
      final raw = await _wifiChannel.invokeMethod<dynamic>('getWifiDiagnostics');
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

  /// SoftAP check used by the home UI. Prefer native flags; fall back to HTTP.
  Future<bool> isOnGatewayFast({bool allowHttpProbe = true}) async {
    try {
      final ok = await _wifiChannel
          .invokeMethod<bool>('isOnGateway')
          .timeout(const Duration(milliseconds: 800));
      if (ok == true) return true;
    } on MissingPluginException {
      // Fall through.
    } on PlatformException {
      // Fall through.
    } on TimeoutException {
      // Fall through.
    }
    try {
      final diag = await wifiDiagnostics()
          .timeout(const Duration(milliseconds: 800));
      final ssid = (diag['ssid'] as String?)?.replaceAll('"', '');
      if (ssid != null &&
          ssid.toLowerCase() == AppConstants.gatewaySsid.toLowerCase()) {
        return true;
      }
      if (diag['onGateway'] == true) return true;
      if (diag['onGatewaySubnet'] == true) return true;
      if (diag['gatewaySsidMatch'] == true) return true;
      if (diag['localOnlyWifi'] == true) return true;
    } catch (_) {}

    if (!allowHttpProbe) return false;
    try {
      return await gatewayHttpReachable()
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }

  /// Peek only — never rebinds process traffic (safe for UI status polls).
  Future<bool> peekHasInternet() async {
    try {
      final native =
          await _wifiChannel.invokeMethod<bool>('hasValidatedInternet');
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
            !await isOnGatewayFast());
  }

  /// May rebind process to LTE for Firebase uploads. Do not call from UI polls.
  Future<bool> hasInternet() async {
    try {
      final native =
          await _wifiChannel.invokeMethod<bool>('hasValidatedInternet');
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
      final ok =
          await _wifiChannel.invokeMethod<bool>('bindToInternetNetwork');
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
      final res =
          await dio.get<dynamic>('${AppConstants.gatewayBaseUrl}/status');
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
