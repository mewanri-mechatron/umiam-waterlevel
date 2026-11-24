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
    this.hint,
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

  /// Short “what to do next” line for the UI.
  final String? hint;
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

  static const _gatewayTimeout = Duration(seconds: 25);
  static const _cloudPullTimeout = Duration(seconds: 30);
  static const _cloudPushTimeout = Duration(seconds: 45);
  static const _cycleWatchdog = Duration(seconds: 50);

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
    try {
      final removed = await _sync.purgeLocalReadingsBeforeToday();
      if (removed > 0) {
        await _audit.info(
          'Cleaned $removed old readings',
          category: 'app',
          detail: 'Kept from today 12:00 AM onward',
        );
      }
    } catch (_) {}
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
    snapshot = AutoSyncSnapshot(
      phase: AutoSyncPhase.idle,
      message: 'At sensor · syncing…',
      hint: 'Pulling buffered readings from the station.',
      stepLabel: 'At sensor',
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
      final onGateway = await _network.isOnGatewayFast(allowHttpProbe: false);
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
      String? hint = prev.hint;
      if (!prev.busy) {
        final status = _idleStatus(
          wifiOn: wifiOn,
          onGateway: onGateway,
          online: online,
          pending: pending,
        );
        step = status.step;
        message = status.message;
        hint = status.hint;
      }

      final messageChanged = step != prev.stepLabel ||
          message != prev.message ||
          hint != prev.hint;
      snapshot = AutoSyncSnapshot(
        phase: prev.busy ? prev.phase : AutoSyncPhase.idle,
        message: message,
        hint: hint,
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

  ({String step, String message, String? hint}) _idleStatus({
    required bool wifiOn,
    required bool onGateway,
    required bool online,
    required int pending,
  }) {
    if (!wifiOn && !online) {
      return (
        step: 'Offline',
        message: 'No WiFi and no mobile data',
        hint: 'Turn on mobile data to send readings, or WiFi near the sensor.',
      );
    }
    if (onGateway) {
      if (pending > 0) {
        return (
          step: 'At sensor',
          message: 'Saved on phone · $pending waiting for cloud',
          hint:
              'Leave WaterLevel WiFi (or turn WiFi off) so mobile data can reach the cloud.',
        );
      }
      return (
        step: 'At sensor',
        message: 'On sensor WiFi · ready',
        hint: 'Collects readings here. Leave SoftAP when you need to upload.',
      );
    }
    if (online) {
      if (pending > 0) {
        return (
          step: 'Waiting to send',
          message: '$pending readings waiting to send',
          hint: 'Tap Sync to push them to the cloud now.',
        );
      }
      return (
        step: 'Online',
        message: 'Online · not at sensor',
        hint: 'Near the station, tap Connect to sensor.',
      );
    }
    if (!wifiOn) {
      return (
        step: 'WiFi off',
        message: 'WiFi is off',
        hint: pending > 0
            ? 'Turn on mobile data and tap Sync to send $pending readings.'
            : 'Turn on WiFi near the sensor, or use mobile data for cloud.',
      );
    }
    return (
      step: 'Waiting',
      message: 'Not at sensor · no internet',
      hint: 'Join WaterLevel near the station, or turn on mobile data.',
    );
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
      try {
        await _runCycleBody(force: force).timeout(_cycleWatchdog);
      } on TimeoutException catch (e) {
        final pending = await _loadPending();
        await _audit.error(
          'Sync cycle · TIMEOUT',
          category: 'sync',
          detail: e.toString(),
        );
        _set(
          AutoSyncPhase.error,
          'Sync timed out · stopped so the app does not hang',
          error: e.toString(),
          hint: snapshot.onGateway && pending > 0
              ? 'Leave WaterLevel WiFi, confirm 4G, then tap Retry Sync.'
              : 'Check mobile data / sensor WiFi, then tap Retry Sync.',
          pendingCount: pending,
        );
      } catch (e) {
        final pending = await _loadPending();
        await _audit.error(
          'Sync cycle · FAILED',
          category: 'sync',
          detail: '$e',
        );
        _set(
          AutoSyncPhase.error,
          'Sync failed',
          error: e.toString(),
          hint: 'Check mobile data / sensor WiFi, then tap Retry Sync.',
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

  Future<void> _runCycleBody({required bool force}) async {
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
        'Offline · no network',
        hint: 'Turn on mobile data to send readings, or WiFi near the sensor.',
        stepLabel: 'Offline',
      );
      return;
    }

    if (onGateway || demo) {
      final canTryGateway = force ||
          _lastGatewayAttempt == null ||
          DateTime.now().difference(_lastGatewayAttempt!) >
              const Duration(seconds: 20);
      if (canTryGateway) {
        _lastGatewayAttempt = DateTime.now();
        _set(
          AutoSyncPhase.downloading,
          'Getting readings from sensor…',
          hint: 'Stay on WaterLevel WiFi until this finishes.',
          busy: true,
          stepLabel: 'Sensor',
          onGateway: true,
        );
        try {
          await _network.bindToGatewayNetwork();
          final result = await _sync
              .downloadFromGateway()
              .timeout(_gatewayTimeout);
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
          final leaveHint = pending > 0
              ? 'Leave WaterLevel WiFi (or turn WiFi off) so mobile data can reach the cloud.'
              : 'Collects readings here. Leave SoftAP when you need to upload.';
          if (result.inserted > 0) {
            _set(
              AutoSyncPhase.idle,
              'Saved ${result.inserted} new readings'
              '${pending > 0 ? ' · $pending waiting to send' : ''}',
              hint: leaveHint,
              stepLabel: 'At sensor',
              pendingCount: pending,
              onGateway: true,
            );
          } else if (result.downloaded == 0) {
            _set(
              AutoSyncPhase.idle,
              'At sensor · no new readings yet',
              hint: leaveHint,
              stepLabel: 'At sensor',
              pendingCount: pending,
              onGateway: true,
            );
          } else {
            _set(
              AutoSyncPhase.idle,
              'At sensor · already saved'
              '${pending > 0 ? ' · $pending waiting to send' : ''}',
              hint: leaveHint,
              stepLabel: 'At sensor',
              pendingCount: pending,
              onGateway: true,
            );
          }
        } on TimeoutException catch (e) {
          await _audit.error(
            'Sensor download · TIMEOUT',
            category: 'sensor',
            detail: e.toString(),
          );
          _set(
            AutoSyncPhase.error,
            'Sensor timed out',
            error: e.toString(),
            hint:
                'Sensor not responding on WaterLevel. Move closer and reconnect SoftAP, then tap Retry Sync.',
            stepLabel: 'Sensor error',
            onGateway: true,
          );
        } catch (e) {
          await _audit.error(
            'Sensor download · FAILED',
            category: 'sensor',
            detail: e.toString(),
          );
          _set(
            AutoSyncPhase.error,
            'Could not get readings from sensor',
            error: e.toString(),
            hint:
                'Stay on WaterLevel WiFi near the station, then tap Retry Sync.',
            stepLabel: 'Sensor error',
            onGateway: true,
          );
        }
      }
    }

    // Cloud: pull shared settings + readings, then push local pending.
    var canUpload = await _network.peekHasInternet();
    final pendingBeforeCloud = await _loadPending();
    var wifiPausedForUpload = false;

    // SoftAP blocks cloud. Pause WiFi briefly so LTE can carry the upload.
    if (onGateway && pendingBeforeCloud > 0 && !canUpload) {
      _set(
        AutoSyncPhase.uploading,
        'Pausing SoftAP WiFi to reach cloud…',
        hint: 'Turning WiFi off briefly so mobile data can upload.',
        busy: true,
        stepLabel: 'Cloud',
        pendingCount: pendingBeforeCloud,
        onGateway: true,
      );
      wifiPausedForUpload = await _network.pauseWifiForCloudUpload();
      if (wifiPausedForUpload) {
        await Future<void>.delayed(const Duration(seconds: 4));
        await _network.bindToInternetNetwork();
        canUpload = await _network.peekHasInternet();
        onGateway = false;
      }
    }

    if (!canUpload && !online && pendingBeforeCloud > 0) {
      if (wifiPausedForUpload) {
        await _network.resumeWifiAfterCloudUpload();
      }
      _set(
        AutoSyncPhase.error,
        'Saved on phone · $pendingBeforeCloud waiting for cloud',
        hint:
            'Turn on mobile data, leave WaterLevel WiFi, then tap Retry Sync.',
        stepLabel: 'Waiting to send',
        pendingCount: pendingBeforeCloud,
      );
      return;
    }

    if (canUpload || (force && (online || canUpload))) {
      final canTryUpload = force ||
          _lastUploadAttempt == null ||
          DateTime.now().difference(_lastUploadAttempt!) >
              const Duration(seconds: 15);
      if (canTryUpload) {
        _lastUploadAttempt = DateTime.now();

        _set(
          AutoSyncPhase.downloading,
          'Getting data from cloud…',
          hint: 'Using mobile data / internet WiFi.',
          busy: true,
          stepLabel: 'Cloud',
        );
        try {
          await _network.bindToInternetNetwork();
          final pull = await _sync
              .pullFromFirebase()
              .timeout(_cloudPullTimeout);
          await _audit.info(
            'Cloud get · OK',
            category: 'cloud',
            detail: pull.message,
          );
        } on TimeoutException catch (e) {
          await _audit.warn(
            'Cloud get · TIMEOUT',
            category: 'cloud',
            detail: e.toString(),
          );
        } catch (e) {
          await _audit.warn(
            'Cloud get · skipped',
            category: 'cloud',
            detail: e.toString(),
          );
        }

        final beforePending = await _loadPending();
        if (beforePending == 0 && !force) {
          if (wifiPausedForUpload) {
            await _network.resumeWifiAfterCloudUpload();
          }
          _set(
            AutoSyncPhase.idle,
            snapshot.onGateway
                ? 'At sensor · cloud is up to date'
                : 'Up to date',
            hint: snapshot.onGateway
                ? 'No pending uploads. You can leave SoftAP anytime.'
                : 'Cloud matches this phone.',
            stepLabel: snapshot.onGateway ? 'At sensor' : 'Up to date',
            pendingCount: 0,
          );
        } else if (beforePending > 0 || force) {
          _set(
            AutoSyncPhase.uploading,
            beforePending > 0
                ? 'Sending $beforePending readings to cloud…'
                : 'Checking cloud…',
            hint: onGateway
                ? 'If this stalls, leave WaterLevel WiFi and tap Retry Sync.'
                : 'Keep mobile data on until finished.',
            busy: true,
            stepLabel: 'Sending',
            pendingCount: beforePending,
          );
          try {
            await _network.bindToInternetNetwork();
            var result = await _sync
                .uploadPendingToFirebase()
                .timeout(_cloudPushTimeout);
            if (result.message == 'Upload already in progress.') {
              await Future<void>.delayed(const Duration(seconds: 2));
              result = await _sync
                  .uploadPendingToFirebase()
                  .timeout(_cloudPushTimeout);
            }
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
                    ? 'Sent ${result.uploaded} · $pending still waiting'
                    : 'Sent ${result.uploaded} · up to date',
                hint: pending > 0
                    ? (onGateway
                        ? 'Leave WaterLevel WiFi so the rest can upload.'
                        : 'Tap Sync again to send the rest.')
                    : 'Cloud is up to date.',
                stepLabel: onGateway ? 'At sensor' : 'Up to date',
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
                AutoSyncPhase.error,
                '$pending waiting · no internet path',
                error: detail,
                hint:
                    'Leave WaterLevel WiFi, confirm 4G in the status bar, then tap Retry Sync.',
                stepLabel: 'Waiting to send',
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
                'Could not send to cloud · $pending still on phone',
                error: detail,
                hint:
                    'Leave SoftAP if connected, confirm mobile data, then tap Retry Sync.',
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
                '$pending still waiting to send',
                hint: onGateway
                    ? 'Leave WaterLevel WiFi so mobile data can upload.'
                    : 'Tap Sync to try again.',
                stepLabel: 'Waiting to send',
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
                'Up to date',
                hint: 'Cloud matches this phone.',
                stepLabel: onGateway ? 'At sensor' : 'Up to date',
                pendingCount: 0,
                onGateway: onGateway,
              );
            }
          } on TimeoutException catch (e) {
            final pending = await _loadPending();
            if (await _network.isOnGatewayFast()) {
              await _network.bindToGatewayNetwork();
              onGateway = true;
            }
            await _audit.error(
              'Cloud push · TIMEOUT',
              category: 'cloud',
              detail: e.toString(),
            );
            _set(
              AutoSyncPhase.error,
              'Cloud send timed out · $pending still on phone',
              error: e.toString(),
              hint:
                  'Leave WaterLevel WiFi, confirm 4G, then tap Retry Sync.',
              stepLabel: 'Cloud error',
              pendingCount: pending,
              onGateway: onGateway,
            );
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
              'Could not send · $pending still on phone',
              error: e.toString(),
              hint:
                  'Leave SoftAP if connected, confirm mobile data, then tap Retry Sync.',
              stepLabel: 'Cloud error',
              pendingCount: pending,
              onGateway: onGateway,
            );
          } finally {
            if (wifiPausedForUpload) {
              await _network.resumeWifiAfterCloudUpload();
              if (await _network.isOnGatewayFast()) {
                await _network.bindToGatewayNetwork();
                onGateway = true;
              }
            }
          }
        }
      }
    } else if (!onGateway && !demo) {
      final pending = await _loadPending();
      final status = _idleStatus(
        wifiOn: wifiOn,
        onGateway: false,
        online: online,
        pending: pending,
      );
      _set(
        AutoSyncPhase.idle,
        status.message,
        hint: status.hint,
        stepLabel: status.step,
        pendingCount: pending,
      );
    }
  }

  void _set(
    AutoSyncPhase phase,
    String message, {
    String? error,
    String? hint,
    bool busy = false,
    String? stepLabel,
    int? pendingCount,
    bool? onGateway,
  }) {
    if (_disposed) return;
    snapshot = AutoSyncSnapshot(
      phase: phase,
      message: message,
      hint: hint,
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
