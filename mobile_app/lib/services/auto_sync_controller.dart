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
    _sub = _network.onConnectivityChanged.listen((_) => unawaited(runCycle()));
    await runCycle();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(runCycle());
    }
  }

  Future<void> runCycle({bool force = false}) async {
    if (_running) return;
    _running = true;
    try {
      final onGateway = await _network.isConnectedToGatewayWifi();
      final demo = _isDemoMode();
      final online = await _network.hasInternet();
      final now = DateTime.now();

      if (onGateway || demo || force) {
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
            _set(
              AutoSyncPhase.idle,
              result.inserted > 0
                  ? 'Saved ${result.inserted} new readings on this phone'
                  : 'Sensor checked · no new readings',
            );
          } catch (e) {
            _set(
              AutoSyncPhase.error,
              'Could not reach sensor gateway',
              error: e.toString(),
            );
          }
        }
      }

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
            final result = await _sync.uploadPendingToFirebase();
            if (result.uploaded > 0) {
              _set(
                AutoSyncPhase.idle,
                'Sent ${result.uploaded} readings to cloud',
              );
            } else if (result.message != null &&
                result.message!.contains('Firebase')) {
              _set(
                AutoSyncPhase.idle,
                'Readings are saved on this phone · cloud not configured yet',
              );
            } else if ((result.pendingRemaining) > 0) {
              _set(
                AutoSyncPhase.idle,
                '${result.pendingRemaining} readings waiting for internet',
              );
            } else {
              _set(AutoSyncPhase.idle, 'Everything is up to date');
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
