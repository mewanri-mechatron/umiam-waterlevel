import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

import 'audit_log_service.dart';
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
    this.stepLabel,
    this.wifiOn = true,
    this.onGateway = false,
    this.hasInternet = false,
    this.pendingCount = 0,
  });

  final AutoSyncPhase phase;
  final String message;
  final String? lastError;
  final bool busy;
  final String? stepLabel;
  final bool wifiOn;
  final bool onGateway;
  final bool hasInternet;
  final int pendingCount;
}

/// Field sync while the app is open. System WiFi dialogs are only opened from
/// explicit user taps on home — never automatically.
class AutoSyncController extends ChangeNotifier with WidgetsBindingObserver {
  AutoSyncController({
    required SyncService syncService,
    required NetworkService networkService,
    required AuditLogService auditLog,
    required bool Function() isDemoMode,
    Future<int> Function()? pendingCountLoader,
  }) {
    _sync = syncService;
    _network = networkService;
    _audit = auditLog;
    _isDemoMode = isDemoMode;
    _pendingCountLoader = pendingCountLoader;
  }

  late final SyncService _sync;
  late final NetworkService _network;
  late final AuditLogService _audit;
  late final bool Function() _isDemoMode;
  Future<int> Function()? _pendingCountLoader;

  StreamSubscription<List<ConnectivityResult>>? _sub;
  StreamSubscription<Map<String, dynamic>>? _gatewaySub;
  Timer? _statusTimer;
  Timer? _debounce;
  bool _started = false;
  bool _running = false;
  bool _refreshing = false;
  bool _disposed = false;
  DateTime? _lastGatewayAttempt;
  DateTime? _lastUploadAttempt;
  DateTime? _lastCycleAt;

  AutoSyncSnapshot snapshot = const AutoSyncSnapshot(
    phase: AutoSyncPhase.idle,
    message: 'Ready',
    stepLabel: 'Idle',
  );

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    await _audit.info('App started', category: 'app');
    await refreshConnectionStatus();
    _sub = _network.onConnectivityChanged.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 1), () {
        unawaited(refreshConnectionStatus());
        unawaited(runCycle());
      });
    });
    _gatewaySub = _network.onGatewayEvents.listen((event) {
      final name = event['event']?.toString();
      if (name == 'gateway_connected') {
        unawaited(_onGatewayConnected());
      } else if (name == 'gateway_lost' || name == 'gateway_unavailable') {
        unawaited(refreshConnectionStatus());
      }
    });
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(refreshConnectionStatus());
    });
    await runCycle();
  }

  Future<void> _onGatewayConnected() async {
    await _audit.info(
      'Connected to WaterLevel WiFi',
      category: 'network',
    );
    // Force UI immediately — don't wait for diagnostics.
    snapshot = AutoSyncSnapshot(
      phase: AutoSyncPhase.idle,
      message: 'Connected to WaterLevel · syncing…',
      stepLabel: 'Connected',
      wifiOn: true,
      onGateway: true,
      hasInternet: snapshot.hasInternet,
      pendingCount: snapshot.pendingCount,
    );
    notifyListeners();
    await refreshConnectionStatus();
    await runCycle(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refreshConnectionStatus());
      unawaited(runCycle());
    }
  }

  /// Safe UI poll — never rebinds SoftAP away for internet checks.
  Future<void> refreshConnectionStatus() async {
    if (_disposed || _refreshing) return;
    _refreshing = true;
    try {
      final wifiOn = await _network.isWifiEnabled().timeout(
        const Duration(seconds: 1),
        onTimeout: () => snapshot.wifiOn,
      );
      // HTTP probe when native flags miss SoftAP (common with unknown SSID).
      final onGateway = await _network.isOnGatewayFast(allowHttpProbe: true);
      final online = await _network.peekHasInternet().timeout(
        const Duration(seconds: 1),
        onTimeout: () => snapshot.hasInternet,
      );
      final pending = await _loadPending();
      final prev = snapshot;
      final becameConnected = !prev.onGateway && onGateway;

      final changed = prev.wifiOn != wifiOn ||
          prev.onGateway != onGateway ||
          prev.hasInternet != online ||
          prev.pendingCount != pending;

      String? step = prev.stepLabel;
      String message = prev.message;
      if (!prev.busy) {
        if (!wifiOn) {
          step = 'WiFi off';
          message = 'Turn WiFi on to connect to the sensor or cloud';
        } else if (onGateway) {
          step = 'Connected';
          message = pending > 0
              ? 'On WaterLevel WiFi · $pending waiting to upload'
              : 'On WaterLevel WiFi · ready';
        } else if (online) {
          step = pending > 0 ? 'Pending upload' : 'Ready';
          message = pending > 0
              ? '$pending readings on phone waiting for cloud'
              : 'WiFi on · tap Connect to join WaterLevel near the station';
        } else {
          step = 'Waiting';
          message =
              'WiFi on · join WaterLevel near the station, or use mobile data to upload';
        }
      }

      final messageChanged = step != prev.stepLabel || message != prev.message;
      snapshot = AutoSyncSnapshot(
        phase: prev.busy ? prev.phase : AutoSyncPhase.idle,
        message: message,
        lastError: prev.lastError,
        busy: prev.busy,
        stepLabel: step,
        wifiOn: wifiOn,
        onGateway: onGateway,
        hasInternet: online,
        pendingCount: pending,
      );
      if (!_disposed && (changed || messageChanged)) notifyListeners();
      if (becameConnected && !_disposed) {
        unawaited(runCycle(force: true));
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<int> _loadPending() async {
    try {
      return await _pendingCountLoader?.call() ?? snapshot.pendingCount;
    } catch (_) {
      return snapshot.pendingCount;
    }
  }

  Future<void> runCycle({bool force = false}) async {
    if (_disposed) return;
    if (_running) {
      if (!force) return;
      for (var i = 0; i < 40 && _running; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (_running || _disposed) return;
    }

    final now = DateTime.now();
    if (!force &&
        _lastCycleAt != null &&
        now.difference(_lastCycleAt!) < const Duration(seconds: 8)) {
      await refreshConnectionStatus();
      return;
    }

    _running = true;
    _lastCycleAt = now;
    try {
      await refreshConnectionStatus();
      var onGateway = snapshot.onGateway;
      final demo = _isDemoMode();
      final wifiOn = snapshot.wifiOn;
      final online = snapshot.hasInternet;

      if (force) {
        await _audit.info('Manual sync started', category: 'sync');
      }

      if (!wifiOn && !online && !demo) {
        _set(
          AutoSyncPhase.idle,
          'WiFi is off · tap Turn on WiFi',
          stepLabel: 'WiFi off',
        );
        return;
      }

      if (onGateway || demo) {
        final canTryGateway = force ||
            _lastGatewayAttempt == null ||
            now.difference(_lastGatewayAttempt!) > const Duration(seconds: 20);
        if (canTryGateway) {
          _lastGatewayAttempt = now;
          _set(
            AutoSyncPhase.downloading,
            'Connected · downloading from sensor…',
            busy: true,
            stepLabel: 'Downloading',
            onGateway: true,
          );
          try {
            await _network.bindToGatewayNetwork();
            final result = await _sync.downloadFromGateway();
            final pending = await _loadPending();
            await _audit.info(
              result.inserted > 0
                  ? 'Sensor download · SUCCESS'
                  : 'Sensor download · OK',
              category: 'sensor',
              detail:
                  'new=${result.inserted} already_saved=${result.duplicates} '
                  'pending_upload=$pending'
                  '${result.message == null ? '' : ' · ${result.message}'}',
            );
            if (result.inserted > 0) {
              _set(
                AutoSyncPhase.idle,
                'Saved ${result.inserted} new readings · $pending waiting to upload',
                stepLabel: 'Connected',
                pendingCount: pending,
                onGateway: true,
              );
            } else if (result.downloaded == 0) {
              _set(
                AutoSyncPhase.idle,
                'Connected · sensor has no new readings yet',
                stepLabel: 'Connected',
                pendingCount: pending,
                onGateway: true,
              );
            } else {
              _set(
                AutoSyncPhase.idle,
                'Connected · no new readings ($pending pending upload)',
                stepLabel: 'Connected',
                pendingCount: pending,
                onGateway: true,
              );
            }
          } catch (e) {
            await _audit.error(
              'Sensor download · FAILED',
              category: 'sensor',
              detail: e.toString(),
            );
            _set(
              AutoSyncPhase.error,
              'Connected but could not download from sensor',
              error: e.toString(),
              stepLabel: 'Sensor error',
              onGateway: true,
            );
          }
        }
      }

      // Upload only if there is a real internet path — peek first so SoftAP stays.
      final canUpload = await _network.peekHasInternet();
      if (canUpload || (force && online)) {
        final canTryUpload = force ||
            _lastUploadAttempt == null ||
            now.difference(_lastUploadAttempt!) > const Duration(seconds: 15);
        if (canTryUpload) {
          _lastUploadAttempt = DateTime.now();
          final beforePending = await _loadPending();
          if (beforePending == 0 && !force) {
            _set(
              AutoSyncPhase.idle,
              snapshot.onGateway
                  ? 'Connected · everything is on the cloud'
                  : 'Everything is up to date',
              stepLabel: snapshot.onGateway ? 'Connected' : 'Up to date',
              pendingCount: 0,
            );
          } else if (beforePending > 0 || force) {
            _set(
              AutoSyncPhase.uploading,
              beforePending > 0
                  ? 'Uploading $beforePending readings to cloud…'
                  : 'Checking cloud…',
              busy: true,
              stepLabel: 'Uploading',
              pendingCount: beforePending,
            );
            try {
              await _network.bindToInternetNetwork();
              var result = await _sync.uploadPendingToFirebase();
              if (result.message == 'Upload already in progress.') {
                await Future<void>.delayed(const Duration(seconds: 2));
                result = await _sync.uploadPendingToFirebase();
              }
              // Restore SoftAP bind if still associated.
              if (await _network.isOnGatewayFast()) {
                await _network.bindToGatewayNetwork();
                onGateway = true;
              }
              final detail = result.message ?? '';
              final pending = result.pendingRemaining < 0
                  ? await _loadPending()
                  : result.pendingRemaining;

              if (result.uploaded > 0 && result.failed == 0) {
                await _audit.info(
                  'Cloud push · SUCCESS',
                  category: 'cloud',
                  detail:
                      'uploaded=${result.uploaded} pending=$pending'
                      '${detail.isEmpty ? '' : ' · $detail'}',
                );
                _set(
                  AutoSyncPhase.idle,
                  pending > 0
                      ? 'Pushed ${result.uploaded} · $pending still pending'
                      : 'Pushed ${result.uploaded} · cloud is up to date',
                  stepLabel: onGateway ? 'Connected' : 'Up to date',
                  pendingCount: pending,
                  onGateway: onGateway,
                );
              } else if (detail.startsWith('No internet') ||
                  result.pendingRemaining < 0) {
                await _audit.warn(
                  'Cloud push · PENDING (no internet)',
                  category: 'cloud',
                  detail: 'pending=$pending · $detail',
                );
                _set(
                  AutoSyncPhase.idle,
                  '$pending readings pending · need internet to upload',
                  stepLabel: 'Pending upload',
                  pendingCount: pending,
                  onGateway: onGateway,
                );
              } else if (result.failed > 0) {
                await _audit.error(
                  'Cloud push · FAILED',
                  category: 'cloud',
                  detail:
                      'uploaded=${result.uploaded} failed=${result.failed} '
                      'pending=$pending · $detail',
                );
                _set(
                  AutoSyncPhase.error,
                  'Cloud push failed · $pending still on phone',
                  error: detail,
                  stepLabel: 'Cloud error',
                  pendingCount: pending,
                  onGateway: onGateway,
                );
              } else if (pending > 0) {
                await _audit.warn(
                  'Cloud push · PENDING',
                  category: 'cloud',
                  detail: 'pending=$pending · $detail',
                );
                _set(
                  AutoSyncPhase.idle,
                  '$pending readings still pending upload',
                  stepLabel: 'Pending upload',
                  pendingCount: pending,
                  onGateway: onGateway,
                );
              } else {
                await _audit.info(
                  'Cloud push · SUCCESS (nothing pending)',
                  category: 'cloud',
                  detail: detail.isEmpty ? 'queue empty' : detail,
                );
                _set(
                  AutoSyncPhase.idle,
                  'Everything is up to date',
                  stepLabel: onGateway ? 'Connected' : 'Up to date',
                  pendingCount: 0,
                  onGateway: onGateway,
                );
              }
            } catch (e) {
              final pending = await _loadPending();
              if (await _network.isOnGatewayFast()) {
                await _network.bindToGatewayNetwork();
                onGateway = true;
              }
              await _audit.error(
                'Cloud push · FAILED',
                category: 'cloud',
                detail: e.toString(),
              );
              _set(
                AutoSyncPhase.error,
                'Cloud send failed · $pending still safe on phone',
                error: e.toString(),
                stepLabel: 'Cloud error',
                pendingCount: pending,
                onGateway: onGateway,
              );
            }
          }
        }
      } else if (!onGateway && !demo) {
        final pending = await _loadPending();
        _set(
          AutoSyncPhase.idle,
          pending > 0
              ? '$pending pending · connect to WaterLevel or get internet'
              : 'Tap Connect to WaterLevel WiFi near the station',
          stepLabel: pending > 0 ? 'Pending upload' : 'Ready',
          pendingCount: pending,
        );
      }
    } finally {
      _running = false;
      if (!_disposed) {
        await refreshConnectionStatus();
        notifyListeners();
      }
    }
  }

  void _set(
    AutoSyncPhase phase,
    String message, {
    String? error,
    bool busy = false,
    String? stepLabel,
    int? pendingCount,
    bool? onGateway,
  }) {
    if (_disposed) return;
    snapshot = AutoSyncSnapshot(
      phase: phase,
      message: message,
      lastError: error,
      busy: busy,
      stepLabel: stepLabel,
      wifiOn: snapshot.wifiOn,
      onGateway: onGateway ?? snapshot.onGateway,
      hasInternet: snapshot.hasInternet,
      pendingCount: pendingCount ?? snapshot.pendingCount,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _statusTimer?.cancel();
    unawaited(_sub?.cancel());
    unawaited(_gatewaySub?.cancel());
    super.dispose();
  }
}
