import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

import 'network_service.dart';
import 'sync_service.dart';

enum AutoSyncPhase {
  idle,
  downloading,
  uploading,
  error,
}

class AutoSyncSnapshot {
  const AutoSyncSnapshot({
    required this.phase,
    required this.message,
    this.lastError,
    this.busy = false,
  });

  final AutoSyncPhase phase;
  final String message;
  final String? lastError;
  final bool busy;
}

/// Keeps field sync automatic while the app is running.
/// Cloud upload can also run in background via WorkManager when Android allows it.
class AutoSyncController extends ChangeNotifier with WidgetsBindingObserver {
  AutoSyncController({
    required SyncService syncService,
    required NetworkService networkService,
    required bool Function() isDemoMode,
  }) {
    _sync = syncService;
    _network = networkService;
    _isDemoMode = isDemoMode;
  }

  late final SyncService _sync;
  late final NetworkService _network;
  late final bool Function() _isDemoMode;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _started = false;
  bool _running = false;
  DateTime? _lastGatewayAttempt;
  DateTime? _lastUploadAttempt;

  AutoSyncSnapshot snapshot = const AutoSyncSnapshot(
    phase: AutoSyncPhase.idle,
    message: 'Starting…',
  );

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    await _network.requestWifiPermissions();
    _sub = _network.onConnectivityChanged.listen((_) => unawaited(runCycle()));
    await runCycle(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(runCycle());
    }
  }

  Future<void> runCycle({bool force = false}) async {
    // Force (Sync now) waits briefly for an in-flight cycle instead of no-op.
    if (_running) {
      if (!force) return;
      for (var i = 0; i < 40 && _running; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (_running) return;
    }
    _running = true;
    try {
      final onGateway = await _network.isConnectedToGatewayWifi();
      final demo = _isDemoMode();
      final online = await _network.hasInternet();
      final now = DateTime.now();
      final diag = await _network.wifiDiagnostics();
      // ignore: avoid_print
      print(
        'WaterLevel sync: onGateway=$onGateway demo=$demo online=$online '
        'ssid=${diag['ssid']} ipv4=${diag['ipv4']} subnet=${diag['onGatewaySubnet']}',
      );

      // Only hit the ESP when actually on SoftAP (or demo). Don't force
      // gateway download while on normal internet — that races the upload.
      if (onGateway || demo) {
        final canTryGateway = force ||
            _lastGatewayAttempt == null ||
            now.difference(_lastGatewayAttempt!) > const Duration(seconds: 20);
        if (canTryGateway) {
          _lastGatewayAttempt = now;
          _set(
            AutoSyncPhase.downloading,
            'Getting readings from sensor…',
            busy: true,
          );
          try {
            final result = await _sync.downloadFromGateway();
            if (result.inserted > 0) {
              _set(
                AutoSyncPhase.idle,
                'Saved ${result.inserted} new readings on this phone',
              );
            } else if (result.downloaded == 0) {
              final note = result.message == null || result.message!.isEmpty
                  ? ''
                  : ' · ${result.message}';
              _set(
                AutoSyncPhase.idle,
                'ESP reachable, 0 readings in queue$note. '
                'Check Node A→LoRa→Node B, or open http://192.168.4.1/data?since=0 on the phone',
              );
            } else {
              _set(
                AutoSyncPhase.idle,
                'Sensor checked · ${result.duplicates} already saved, no new rows',
              );
            }
          } catch (e) {
            _set(
              AutoSyncPhase.error,
              'Could not reach sensor gateway',
              error: e.toString(),
            );
          }
        }
      }

      // SoftAP has no internet — bind LTE/validated data before Firebase.
      await _network.clearNetworkBinding();
      await _network.bindToInternetNetwork();
      final onlineNow = await _network.hasInternet();
      if (onlineNow || (force && online)) {
        final canTryUpload = force ||
            _lastUploadAttempt == null ||
            now.difference(_lastUploadAttempt!) > const Duration(seconds: 15);
        if (canTryUpload) {
          _lastUploadAttempt = DateTime.now();
          _set(
            AutoSyncPhase.uploading,
            'Sending saved readings to cloud…',
            busy: true,
          );
          try {
            await _network.bindToInternetNetwork();
            var result = await _sync.uploadPendingToFirebase();
            // Another uploader (startup / WorkManager overlap) — wait and retry once.
            if (result.message == 'Upload already in progress.') {
              _set(
                AutoSyncPhase.uploading,
                'Cloud upload already running…',
                busy: true,
              );
              await Future<void>.delayed(const Duration(seconds: 2));
              result = await _sync.uploadPendingToFirebase();
            }
            final detail = result.message ?? '';
            final busyMsg = detail == 'Upload already in progress.';
            final noopMsg = detail == 'Nothing pending for upload.' ||
                detail.startsWith('No internet');
            if (result.uploaded > 0) {
              _set(
                AutoSyncPhase.idle,
                'Sent ${result.uploaded} readings to cloud'
                '${result.pendingRemaining > 0 ? ' · ${result.pendingRemaining} still pending' : ''}',
              );
            } else if (result.pendingRemaining < 0 ||
                detail.startsWith('No internet')) {
              _set(
                AutoSyncPhase.idle,
                'No internet for cloud upload · ${await _network.wifiDiagnostics().then((d) => d['ssid']) ?? 'WiFi'}',
              );
            } else if (busyMsg) {
              _set(
                AutoSyncPhase.idle,
                'Cloud upload in progress · ${result.pendingRemaining} still on phone',
              );
            } else if (result.failed > 0) {
              final short = detail.contains('permission-denied')
                  ? 'Cloud permission denied · ${result.pendingRemaining} still on phone'
                  : detail.toLowerCase().contains('anonymous')
                      ? 'Cloud auth failed · enable Anonymous Auth in Firebase'
                      : 'Cloud upload failed · ${result.pendingRemaining} still on phone';
              _set(
                AutoSyncPhase.error,
                short,
                error: detail,
              );
            } else if (result.pendingRemaining > 0) {
              _set(
                AutoSyncPhase.idle,
                '${result.pendingRemaining} readings still pending upload',
              );
            } else if (noopMsg || detail.isEmpty) {
              _set(AutoSyncPhase.idle, 'Everything is up to date');
            } else {
              _set(AutoSyncPhase.idle, detail);
            }
          } catch (e) {
            _set(
              AutoSyncPhase.error,
              'Cloud send failed · data is still safe on phone',
              error: e.toString(),
            );
          }
        }
      } else if (!onGateway && !demo) {
        _set(
          AutoSyncPhase.idle,
          'Waiting · connect to WaterLevel WiFi for sensor, or internet to send',
        );
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  void _set(AutoSyncPhase phase, String message, {String? error, bool busy = false}) {
    snapshot = AutoSyncSnapshot(
      phase: phase,
      message: message,
      lastError: error,
      busy: busy,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
