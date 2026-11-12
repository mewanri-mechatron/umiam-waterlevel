import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../core/constants/app_constants.dart';

class NetworkService {
  NetworkService({
    Connectivity? connectivity,
    MethodChannel? wifiChannel,
  })  : _connectivity = connectivity ?? Connectivity(),
        _wifiChannel = wifiChannel ??
            const MethodChannel('com.waterlevel.app/wifi');

  final Connectivity _connectivity;
  final MethodChannel _wifiChannel;

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

  Future<bool> hasInternet() async {
    // Prefer native check: SoftAP often advertises INTERNET but is not VALIDATED.
    try {
      final native = await _wifiChannel.invokeMethod<bool>('hasValidatedInternet');
      if (native == true) {
        await bindToInternetNetwork();
        return true;
      }
      if (native == false) {
        // Still try binding — LTE may be up even if the first probe raced.
        if (await bindToInternetNetwork()) return true;
      }
    } on MissingPluginException {
      // Background isolate: SiteSyncService already bound LTE process-wide.
    } on PlatformException {
      // Fall through.
    }

    final results = await _connectivity.checkConnectivity();
    if (results.contains(ConnectivityResult.none) || results.isEmpty) {
      return false;
    }
    final onGateway = await isConnectedToGatewayWifi();
    final hasMobile = results.contains(ConnectivityResult.mobile);
    if (onGateway) {
      if (hasMobile) {
        final bound = await bindToInternetNetwork();
        // true even if MethodChannel missing — FGS may already have bound LTE.
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

  /// Bind process traffic to cellular / validated WiFi (not SoftAP).
  Future<bool> bindToInternetNetwork() async {
    try {
      final ok =
          await _wifiChannel.invokeMethod<bool>('bindToInternetNetwork');
      return ok ?? false;
    } on MissingPluginException {
      await clearNetworkBinding();
      return false;
    } on PlatformException {
      await clearNetworkBinding();
      return false;
    }
  }

  /// True if SSID matches, phone has a 192.168.4.x address, or ESP /status answers.
  Future<bool> isConnectedToGatewayWifi() async {
    try {
      final diag = await wifiDiagnostics();
      final ssid = (diag['ssid'] as String?)?.replaceAll('"', '');
      if (ssid == AppConstants.gatewaySsid) return true;
      if (diag['onGatewaySubnet'] == true) return true;
      if (diag['gatewaySsidMatch'] == true) return true;
    } catch (_) {
      // Continue with legacy SSID read.
    }

    try {
      final ssid = await _wifiChannel.invokeMethod<String>('getWifiSsid');
      if (ssid != null && ssid.replaceAll('"', '') == AppConstants.gatewaySsid) {
        return true;
      }
    } on MissingPluginException {
      // Ignore.
    } on PlatformException {
      // Ignore.
    }

    // Last resort: can we speak to the SoftAP HTTP server?
    return gatewayHttpReachable();
  }

  Future<bool> gatewayHttpReachable() async {
    try {
      await bindToGatewayNetwork();
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
          validateStatus: (_) => true,
        ),
      );
      final res = await dio.get<dynamic>('${AppConstants.gatewayBaseUrl}/status');
      return res.statusCode != null && res.statusCode! < 500;
    } catch (_) {
      try {
        final dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
            validateStatus: (_) => true,
          ),
        );
        final res = await dio.get<dynamic>('${AppConstants.gatewayBaseUrl}/');
        return res.statusCode != null;
      } catch (_) {
        return false;
      }
    }
  }

  Map<String, String> get _gatewayWifiArgs => {
        'ssid': AppConstants.gatewaySsid,
        'password': AppConstants.gatewayPassword,
      };

  Future<String> requestGatewayWifiConnection() async {
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
}
