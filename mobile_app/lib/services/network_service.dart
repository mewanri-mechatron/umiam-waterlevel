import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
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

  Future<bool> hasInternet() async {
    final results = await _connectivity.checkConnectivity();
    if (results.contains(ConnectivityResult.none) || results.isEmpty) {
      return false;
    }
    // Connected to WaterLevel AP typically has WiFi but no internet.
    final onGateway = await isConnectedToGatewayWifi();
    if (onGateway) return false;
    return results.any(
      (r) =>
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet,
    );
  }

  Future<bool> isConnectedToGatewayWifi() async {
    try {
      final ssid = await _wifiChannel.invokeMethod<String>('getWifiSsid');
      if (ssid == null) return false;
      final normalized = ssid.replaceAll('"', '');
      return normalized == AppConstants.gatewaySsid;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Asks native layer to open system WiFi / suggest WaterLevel network.
  Future<String> requestGatewayWifiConnection() async {
    try {
      final result =
          await _wifiChannel.invokeMethod<String>('connectToGatewayWifi');
      return result ?? 'Follow the system WiFi prompt to join WaterLevel.';
    } on MissingPluginException {
      return 'Open WiFi settings and connect to SSID "${AppConstants.gatewaySsid}".';
    } on PlatformException catch (e) {
      return e.message ??
          'Unable to start WiFi connection. Connect manually to ${AppConstants.gatewaySsid}.';
    }
  }

  /// Register WaterLevel so Android can auto-join when the phone is nearby.
  Future<String> suggestGatewayWifi() async {
    try {
      final result =
          await _wifiChannel.invokeMethod<String>('suggestGatewayWifi');
      return result ?? 'WiFi suggestion registered.';
    } on MissingPluginException {
      return 'Open WiFi settings and connect to SSID "${AppConstants.gatewaySsid}".';
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

  /// Bind process / socket traffic to the gateway network when possible.
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
