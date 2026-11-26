import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

import 'audit_log_service.dart';
import 'network_service.dart';
import 'sync_service.dart';

enum AutoSyncPhase { idle, downloading, uploading, error }

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
  static const _cycleWatchdog = Duration(seconds: 75);

  /// How often to auto-retry when readings are waiting / at the sensor.
  static const _catchUpPendingGap = Duration(seconds: 45);
  static const _catchUpSensorGap = Duration(seconds: 90);

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
  DateTime? _lastCatchUpAt;
  DateTime? _lastCloudPullAt;
  DateTime? _lastRetentionAt;

  /// A cycle body that outlived the watchdog keeps running (Dart futures are
  /// not cancellable). No new cycle may start until it settles.
  Future<void>? _bodyInFlight;

  static const _leaseOwner = 'ui';
  static const _leaseTtl = Duration(minutes: 3);

  static const _storageFullMessage = 'Phone storage is full';

  int _sensorFailures = 0;
  bool _storageFull = false;

  /// First open (and reinstall) must restore history from the cloud even if
  /// the phone is on sensor WiFi with no pending uploads.
  bool _startupCloudPull = true;
  DateTime? _errorShownAt;
  final Map<String, DateTime> _lastProblemLogAt = {};

  AutoSyncSnapshot snapshot = const AutoSyncSnapshot(
    phase: AutoSyncPhase.idle,
    message: 'Ready',
    stepLabel: 'Idle',
  );

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    final phone = await _network.phoneStatus();
    await _audit.info(
      'App opened',
      category: 'app',
      detail: phone == null
          ? null
          : '${phone.name} · Android ${phone.android} · '
                'app ${phone.appVersion} · free ${phone.freeStorageMb} MB · '
                'battery ${phone.batteryPct}%'
                '${phone.batteryUnrestricted ? '' : ' · battery RESTRICTED'}'
                '${phone.notificationsOn ? '' : ' · notifications OFF'}',
    );
    if (phone != null && phone.storageLow) {
      await _audit.error(
        'Phone storage almost full',
        category: 'app',
        detail: 'free ${phone.freeStorageMb} MB',
      );
    }
    unawaited(_network.requestCloudReport(force: true));
    await _maybeApplyRetention();
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
      unawaited(_maybeStaleCatchUp());
    });
    // Force: pull cloud history + sensor + upload on every cold start.
    await runCycle(force: true);
  }

  Future<void> _maybeApplyRetention() async {
    final now = DateTime.now();
    final last = _lastRetentionAt;
    if (last != null && now.difference(last) < const Duration(hours: 12)) {
      return;
    }
    _lastRetentionAt = now;
    try {
      final removed = await _sync.applyLocalRetention();
      if (removed > 0) {
        await _audit.info(
          'Trimmed $removed old readings',
          category: 'app',
          detail:
              'Already in cloud and older than '
              '${SyncService.localRetention.inDays} days',
        );
      }
    } catch (_) {}
  }

  /// Cloud → phone pull restores history after reinstall and picks up shared
  /// calibration. Always runs once after the app opens.
  Future<bool> _shouldPullFromCloud({required bool manual}) async {
    if (_startupCloudPull) return true;
    final last = _lastCloudPullAt;
    final since = last == null ? null : DateTime.now().difference(last);
    if (manual && (since == null || since > const Duration(minutes: 30))) {
      return true;
    }
    if (since != null && since < const Duration(minutes: 10)) return false;
    try {
      final local = await _sync.countLocalReadings();
      if (local < 20) return true;
    } catch (_) {}
    return since == null || since > const Duration(hours: 6);
  }

  /// Pull cloud readings/calibration. May briefly route over mobile data while
  /// on sensor WiFi so a fresh install still gets history.
  Future<void> _pullFromCloudNow({required bool onGateway}) async {
    _set(
      AutoSyncPhase.downloading,
      'Getting readings from the cloud…',
      hint: 'Please wait.',
      busy: true,
      stepLabel: 'Cloud',
      onGateway: onGateway,
    );
    var releasedSoftAp = false;
    try {
      var canUpload = await _network.peekHasInternet();
      if (!canUpload && onGateway) {
        releasedSoftAp = await _network.pauseWifiForCloudUpload();
        if (releasedSoftAp) {
          await Future<void>.delayed(const Duration(seconds: 2));
          await _network.bindToInternetNetwork();
          canUpload = await _network.peekHasInternet();
        }
      }
      if (!canUpload) {
        await _audit.warn(
          'Cloud restore skipped — no internet',
          category: 'cloud',
        );
        return;
      }
      await _network.bindToInternetNetwork();
      final pull = await _sync.pullFromFirebase().timeout(_cloudPullTimeout);
      _lastCloudPullAt = DateTime.now();
      _startupCloudPull = false;
      await _audit.info(
        'Cloud restore done',
        category: 'cloud',
        detail: pull.message,
      );
      if (pull.inserted > 0) {
        // Dashboard must refresh after SQLite fills from the cloud.
        // Home listens for busy→idle; message change also notifies.
        _set(
          AutoSyncPhase.idle,
          pull.inserted == 1
              ? 'Loaded 1 reading from the cloud'
              : 'Loaded ${pull.inserted} readings from the cloud',
          hint: 'Syncing the rest…',
          stepLabel: 'Cloud',
          onGateway: onGateway,
        );
      }
    } catch (e) {
      await _audit.warn(
        'Cloud restore skipped',
        category: 'cloud',
        detail: e.toString(),
      );
      // Do not clear _startupCloudPull on hard failure — retry next cycle.
    } finally {
      if (releasedSoftAp) {
        await _network.resumeWifiAfterCloudUpload();
        if (await _network.isOnGatewayFast()) {
          await _network.bindToGatewayNetwork();
        }
      }
    }
  }

  /// If pending uploads sit around (or we're at the sensor), keep trying without
  /// waiting for a manual Sync tap. Reuses [runCycle] — no parallel upload path.
  Future<void> _maybeStaleCatchUp() async {
    if (_disposed || _running || _bodyInFlight != null || snapshot.busy) {
      return;
    }

    final pending = snapshot.pendingCount;
    final onGateway = snapshot.onGateway;
    final online = snapshot.hasInternet;
    final demo = _isDemoMode();

    final needsUpload = pending > 0 && (online || onGateway || demo);
    final needsSensorPull = onGateway || demo;
    if (!needsUpload && !needsSensorPull) return;

    final now = DateTime.now();
    final minGap = needsUpload ? _catchUpPendingGap : _catchUpSensorGap;
    if (_lastCatchUpAt != null && now.difference(_lastCatchUpAt!) < minGap) {
      return;
    }

    // Respect the normal cycle cooldown unless we clearly have work to drain.
    if (!needsUpload &&
        _lastCycleAt != null &&
        now.difference(_lastCycleAt!) < minGap) {
      return;
    }

    _lastCatchUpAt = now;
    await runCycle(force: true, fromCatchUp: true);
  }

  Future<void> _onGatewayConnected() async {
    await _audit.info('Connected to sensor WiFi', category: 'network');
    snapshot = AutoSyncSnapshot(
      phase: AutoSyncPhase.idle,
      message: 'Connected to sensor',
      hint: 'Reading the sensor… please wait.',
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
      final onGateway = await _network.isOnGatewayFast(allowHttpProbe: false);
      final online = await _network.peekHasInternet().timeout(
        const Duration(seconds: 1),
        onTimeout: () => snapshot.hasInternet,
      );
      final pending = await _loadPending();
      final prev = snapshot;
      final becameConnected = !prev.onGateway && onGateway;

      final changed =
          prev.wifiOn != wifiOn ||
          prev.onGateway != onGateway ||
          prev.hasInternet != online ||
          prev.pendingCount != pending;

      String? step = prev.stepLabel;
      String message = prev.message;
      String? hint = prev.hint;
      if (!prev.busy && !_holdError(prev)) {
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

      final messageChanged =
          step != prev.stepLabel ||
          message != prev.message ||
          hint != prev.hint;
      snapshot = AutoSyncSnapshot(
        phase: prev.busy || _holdError(prev) ? prev.phase : AutoSyncPhase.idle,
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

  /// Keeps an error on screen long enough to read; "storage full" stays until
  /// a later save succeeds.
  bool _holdError(AutoSyncSnapshot s) {
    if (s.phase != AutoSyncPhase.error) return false;
    if (_storageFull) return true;
    final at = _errorShownAt;
    return at != null &&
        DateTime.now().difference(at) < const Duration(seconds: 60);
  }

  ({String step, String message, String? hint}) _idleStatus({
    required bool wifiOn,
    required bool onGateway,
    required bool online,
    required int pending,
  }) {
    // Guards are not technical: plain words, one clear action at most.
    if (!wifiOn && !online) {
      return (
        step: 'Offline',
        message: 'WiFi and mobile data are off',
        hint: 'Please turn on WiFi and mobile data.',
      );
    }
    if (onGateway) {
      if (pending > 0) {
        return (
          step: 'Connected',
          message: 'Connected to sensor · $pending readings saved',
          hint: online
              ? 'Sending automatically.'
              : 'They will be sent automatically. Keep mobile data on.',
        );
      }
      return (
        step: 'Connected',
        message: 'Connected to sensor · nothing waiting to send',
        hint: 'Waiting for the next sensor reading. Keep the phone charged.',
      );
    }
    if (!wifiOn) {
      return (
        step: 'WiFi off',
        message: 'WiFi is off',
        hint: 'Turn on WiFi so the phone can read the sensor.',
      );
    }
    if (online && pending > 0) {
      return (
        step: 'Sending',
        message: '$pending readings waiting to send',
        hint: 'Sending automatically.',
      );
    }
    return (
      step: 'Not connected',
      message: 'Not connected to the sensor',
      hint: online
          ? 'Near the sensor, tap “Connect to sensor”.'
          : 'Tap “Connect to sensor”. Keep mobile data on.',
    );
  }

  Future<int> _loadPending() async {
    try {
      return await _pendingCountLoader?.call() ?? snapshot.pendingCount;
    } catch (_) {
      return snapshot.pendingCount;
    }
  }

  Future<void> runCycle({bool force = false, bool fromCatchUp = false}) async {
    if (_disposed) return;
    final aggressive = force || fromCatchUp;
    if (_running || _bodyInFlight != null) {
      if (!aggressive) return;
      for (var i = 0; i < 40 && (_running || _bodyInFlight != null); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (_running || _bodyInFlight != null || _disposed) return;
    }

    final now = DateTime.now();
    if (!aggressive &&
        _lastCycleAt != null &&
        now.difference(_lastCycleAt!) < const Duration(seconds: 8)) {
      await refreshConnectionStatus();
      return;
    }

    _running = true;
    _lastCycleAt = now;
    try {
      // The background service / worker share this process's network binding
      // and database; never run a cycle on top of theirs.
      if (!await _network.acquireSyncLease(_leaseOwner, _leaseTtl)) {
        if (force && !fromCatchUp) {
          _set(
            AutoSyncPhase.idle,
            'Sending in the background…',
            hint: 'This screen updates by itself.',
            stepLabel: 'Working',
          );
        }
        return;
      }
      final body = _runCycleBody(force: aggressive, fromCatchUp: fromCatchUp);
      _bodyInFlight = body;
      unawaited(
        body.catchError((Object _) {}).whenComplete(() {
          if (identical(_bodyInFlight, body)) _bodyInFlight = null;
          unawaited(_network.releaseSyncLease(_leaseOwner));
          unawaited(_network.requestCloudReport());
        }),
      );
      try {
        await body.timeout(_cycleWatchdog);
      } on TimeoutException catch (e) {
        final pending = await _loadPending();
        await _audit.error(
          'Sync cycle took too long',
          category: 'sync',
          detail: e.toString(),
        );
        _set(
          AutoSyncPhase.error,
          'Taking longer than usual · will try again',
          error: e.toString(),
          hint: _safeHint(pending),
          pendingCount: pending,
        );
      } catch (e) {
        final pending = await _loadPending();
        await _audit.error('Sync cycle failed', category: 'sync', detail: '$e');
        final problem = _plainProblem(e, pending);
        _set(
          AutoSyncPhase.error,
          problem.message,
          error: e.toString(),
          hint: problem.hint,
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

  String _safeHint(int pending) => pending > 0
      ? 'Readings are safe on this phone. It will try again by itself.'
      : 'It will try again by itself.';

  /// Turns a technical error into one short line a guard can act on.
  ({String message, String hint}) _plainProblem(Object e, int pending) {
    final text = e.toString().toLowerCase();
    if (text.contains('disk is full') ||
        text.contains('sqlite_full') ||
        text.contains('no space left') ||
        text.contains('enospc')) {
      return (
        message: _storageFullMessage,
        hint: 'Delete some photos or videos, then open the app again.',
      );
    }
    return (
      message: 'Could not finish · will try again',
      hint: _safeHint(pending),
    );
  }

  Future<void> _runCycleBody({
    required bool force,
    bool fromCatchUp = false,
  }) async {
    await refreshConnectionStatus();
    var onGateway = snapshot.onGateway;
    final demo = _isDemoMode();
    final wifiOn = snapshot.wifiOn;
    final online = snapshot.hasInternet;

    if (force && !fromCatchUp) {
      await _audit.info('Sync tapped', category: 'sync');
    }

    if (!wifiOn && !online && !demo) {
      _set(
        AutoSyncPhase.idle,
        'WiFi and mobile data are off',
        hint: 'Please turn on WiFi and mobile data.',
        stepLabel: 'Offline',
      );
      return;
    }

    // Restore cloud history first when this phone is empty / just opened,
    // so the Level screen is not blank after reinstall.
    if (await _shouldPullFromCloud(manual: force && !fromCatchUp)) {
      await _pullFromCloudNow(onGateway: onGateway);
      onGateway = await _network.isOnGatewayFast();
    }

    if (onGateway || demo) {
      final canTryGateway =
          force ||
          _lastGatewayAttempt == null ||
          DateTime.now().difference(_lastGatewayAttempt!) >
              const Duration(seconds: 20);
      if (canTryGateway) {
        _lastGatewayAttempt = DateTime.now();
        _set(
          AutoSyncPhase.downloading,
          'Reading the sensor…',
          hint: 'Please wait.',
          busy: true,
          stepLabel: 'Sensor',
          onGateway: true,
        );
        try {
          await _network.bindToGatewayNetwork();
          final result = await _sync.downloadFromGateway().timeout(
            _gatewayTimeout,
          );
          final pending = await _loadPending();
          _sensorFailures = 0;
          if (result.inserted > 0) _storageFull = false;
          if (result.inserted > 0) {
            await _audit.info(
              'Saved ${result.inserted} new readings from sensor',
              category: 'sensor',
              detail:
                  'already_saved=${result.duplicates} waiting=$pending'
                  '${result.message == null ? '' : ' · ${result.message}'}',
            );
          }
          final nextHint = pending > 0
              ? 'Sending automatically.'
              : 'Everything is working.';
          _set(
            AutoSyncPhase.idle,
            result.inserted > 0
                ? 'Saved ${result.inserted} new readings'
                : 'Connected to sensor · no new reading yet',
            hint: nextHint,
            stepLabel: 'Connected',
            pendingCount: pending,
            onGateway: true,
          );
        } catch (e) {
          _sensorFailures++;
          await _auditOnce(
            'sensor_error',
            () => _audit.error(
              e is TimeoutException
                  ? 'Sensor did not answer in time'
                  : 'Could not read the sensor',
              category: 'sensor',
              detail: e.toString(),
            ),
          );
          final problem = _plainProblem(e, 0);
          final storage = problem.message == _storageFullMessage;
          _set(
            AutoSyncPhase.error,
            storage ? problem.message : 'Sensor is not answering',
            error: e.toString(),
            hint: storage
                ? problem.hint
                : (_sensorFailures >= 3
                      ? 'Check that the sensor has power. The app keeps trying.'
                      : 'The app will try again by itself.'),
            stepLabel: 'Sensor',
            onGateway: true,
          );
        }
      }
    }

    // Cloud: optional pull of shared settings/history, then push pending.
    var canUpload = await _network.peekHasInternet();
    final pendingBeforeCloud = await _loadPending();
    var releasedSoftApForUpload = false;

    // Sensor WiFi has no internet. Route over mobile data while WiFi stays on.
    if (onGateway && pendingBeforeCloud > 0 && !canUpload) {
      _set(
        AutoSyncPhase.uploading,
        'Sending readings…',
        hint: 'Please wait.',
        busy: true,
        stepLabel: 'Sending',
        pendingCount: pendingBeforeCloud,
        onGateway: true,
      );
      releasedSoftApForUpload = await _network.pauseWifiForCloudUpload();
      if (releasedSoftApForUpload) {
        await Future<void>.delayed(const Duration(seconds: 2));
        await _network.bindToInternetNetwork();
        canUpload = await _network.peekHasInternet();
        onGateway = false;
      }
    }

    try {
      if (!canUpload && !online && pendingBeforeCloud > 0) {
        await _auditOnce(
          'no_internet',
          () => _audit.warn(
            'No internet — $pendingBeforeCloud readings waiting on phone',
            category: 'cloud',
          ),
        );
        _set(
          AutoSyncPhase.idle,
          '$pendingBeforeCloud readings saved on phone',
          hint:
              'No internet now. Please keep mobile data on — they will be '
              'sent automatically.',
          stepLabel: 'Waiting',
          pendingCount: pendingBeforeCloud,
        );
        return;
      }

      if (canUpload || (force && (online || canUpload))) {
        final canTryUpload =
            force ||
            _lastUploadAttempt == null ||
            DateTime.now().difference(_lastUploadAttempt!) >
                const Duration(seconds: 15);
        if (canTryUpload) {
          _lastUploadAttempt = DateTime.now();

          await _maybeApplyRetention();

          final beforePending = await _loadPending();
          if (beforePending == 0 && !force) {
            _setAllSent();
          } else if (beforePending > 0 || force) {
            _set(
              AutoSyncPhase.uploading,
              beforePending > 0
                  ? 'Sending $beforePending readings…'
                  : 'Checking…',
              hint: 'Please wait.',
              busy: true,
              stepLabel: 'Sending',
              pendingCount: beforePending,
            );
            try {
              await _network.bindToInternetNetwork();
              var result = await _sync.uploadPendingToFirebase().timeout(
                _cloudPushTimeout,
              );
              if (result.message == 'Upload already in progress.') {
                await Future<void>.delayed(const Duration(seconds: 2));
                result = await _sync.uploadPendingToFirebase().timeout(
                  _cloudPushTimeout,
                );
              }
              if (await _network.isOnGatewayFast()) {
                await _network.bindToGatewayNetwork();
                onGateway = true;
              }
              final detail = result.message ?? '';
              final pending = result.pendingRemaining < 0
                  ? await _loadPending()
                  : result.pendingRemaining;

              if (result.uploaded > 0) {
                _storageFull = false;
                await _audit.info(
                  'Sent ${result.uploaded} readings to cloud',
                  category: 'cloud',
                  detail:
                      'waiting=$pending'
                      '${detail.isEmpty ? '' : ' · $detail'}',
                );
              }
              if (pending == 0) {
                _setAllSent(onGateway: onGateway);
              } else {
                final noRoute =
                    detail.startsWith('No internet') ||
                    result.pendingRemaining < 0;
                if (result.failed > 0 || noRoute) {
                  await _auditOnce(
                    noRoute ? 'no_route' : 'upload_failed',
                    () => _audit.warn(
                      noRoute
                          ? 'Upload waiting — no internet path'
                          : 'Upload failed',
                      category: 'cloud',
                      detail:
                          'uploaded=${result.uploaded} '
                          'failed=${result.failed} waiting=$pending · $detail',
                    ),
                  );
                }
                _set(
                  AutoSyncPhase.idle,
                  '$pending readings waiting to send',
                  error: detail.isEmpty ? null : detail,
                  hint: noRoute
                      ? 'No internet now. Please keep mobile data on.'
                      : _safeHint(pending),
                  stepLabel: 'Waiting',
                  pendingCount: pending,
                  onGateway: onGateway,
                );
              }
            } catch (e) {
              final pending = await _loadPending();
              if (await _network.isOnGatewayFast()) {
                await _network.bindToGatewayNetwork();
                onGateway = true;
              }
              await _auditOnce(
                'upload_error',
                () => _audit.error(
                  e is TimeoutException
                      ? 'Upload took too long'
                      : 'Upload failed',
                  category: 'cloud',
                  detail: e.toString(),
                ),
              );
              final problem = _plainProblem(e, pending);
              _set(
                AutoSyncPhase.error,
                pending > 0 && problem.message != _storageFullMessage
                    ? '$pending readings waiting to send'
                    : problem.message,
                error: e.toString(),
                hint: problem.hint,
                stepLabel: 'Waiting',
                pendingCount: pending,
                onGateway: onGateway,
              );
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
    } finally {
      // Restore the sensor WiFi after a SoftAP→LTE handoff. Never open the
      // system WiFi panel from an automatic cycle (it pops up over the app).
      if (releasedSoftApForUpload) {
        await _network.resumeWifiAfterCloudUpload();
        if (await _network.isOnGatewayFast()) {
          await _network.bindToGatewayNetwork();
          // Upload ran off SoftAP; ACK needs sensor WiFi — retry now.
          try {
            await _sync.ackEspAfterCloud();
          } catch (_) {}
        }
      }
    }
  }

  /// Repeating problems (every catch-up cycle) are logged once per 30 min.
  Future<void> _auditOnce(String key, Future<void> Function() log) async {
    final now = DateTime.now();
    final last = _lastProblemLogAt[key];
    if (last != null && now.difference(last) < const Duration(minutes: 30)) {
      return;
    }
    _lastProblemLogAt[key] = now;
    await log();
  }

  void _setAllSent({bool? onGateway}) {
    final atSensor = onGateway ?? snapshot.onGateway;
    _set(
      AutoSyncPhase.idle,
      atSensor
          ? 'Connected to sensor · nothing waiting to send'
          : 'Nothing waiting to send',
      hint: atSensor
          ? 'Waiting for the next sensor reading.'
          : 'Connect to the sensor to collect newer readings.',
      stepLabel: atSensor ? 'Connected' : 'Synced',
      pendingCount: 0,
      onGateway: onGateway,
    );
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
    if (phase == AutoSyncPhase.error) {
      _errorShownAt = DateTime.now();
      if (message == _storageFullMessage) _storageFull = true;
    }
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
