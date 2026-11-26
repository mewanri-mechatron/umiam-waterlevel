import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'core/constants/app_constants.dart';
import 'database/app_database.dart';
import 'services/firebase_service.dart';
import 'services/http_gateway_service.dart';
import 'services/mock_gateway_service.dart';
import 'services/network_service.dart';
import 'services/sync_service.dart';

const _workerLeaseOwner = 'worker';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    final network = NetworkService();
    final reason = inputData?['reason'] as String? ?? 'all';
    // SiteSyncService enqueues "pull" while it already holds the sync lease
    // and waits for us; every other run must take the lease itself.
    final borrowedLease = reason == 'pull';
    var leased = false;
    try {
      if (!borrowedLease) {
        leased = await network.acquireSyncLease(
          _workerLeaseOwner,
          const Duration(minutes: 3),
        );
        if (!leased) return true;
      }

      final prefs = await SharedPreferences.getInstance();
      final useMock = prefs.getBool(AppConstants.prefsUseMockGateway) ?? false;
      if (reason == 'all' &&
          (prefs.getBool(AppConstants.prefsSiteSyncEnabled) ?? true)) {
        // Revive the station service if Android killed it (no-op if running).
        unawaited(network.startSiteSyncService());
      }
      // Shared singleton — never close from a background isolate.
      final db = AppDatabase.instance;
      final firebase = FirebaseService();
      try {
        await firebase.initialize().timeout(const Duration(seconds: 15));
      } catch (_) {
        // Sensor pull still works without Firebase.
      }
      final gateway = useMock
          ? MockGatewayService()
          : HttpGatewayService(networkService: network);
      final sync = SyncService(
        database: db,
        gateway: gateway,
        firebase: firebase,
        network: network,
      );

      final onGateway = await network.isConnectedToGatewayWifi();
      final doPull = reason == 'pull' || reason == 'all';
      final doUpload = reason == 'upload' || reason == 'all';

      if (doPull && (onGateway || useMock)) {
        try {
          if (onGateway) {
            await network.bindToGatewayNetwork();
          }
          final result = await sync.downloadFromGateway().timeout(
            const Duration(seconds: 35),
          );
          if (result.inserted > 0) {
            await _workerLog(
              db,
              prefs,
              'info',
              'sensor',
              'Saved ${result.inserted} new readings from sensor (background)',
            );
          }
        } catch (e) {
          // SoftAP may drop; retry on next tick.
          await _workerLog(
            db,
            prefs,
            'warn',
            'sensor',
            'Background sensor read failed',
            detail: '$e',
          );
        }
      }

      if (doUpload) {
        try {
          await network.bindToInternetNetwork();
          final result = await sync.uploadPendingToFirebase().timeout(
            const Duration(seconds: 90),
          );
          if (result.uploaded > 0) {
            await _workerLog(
              db,
              prefs,
              'info',
              'cloud',
              'Sent ${result.uploaded} readings to cloud (background)',
            );
          }
        } catch (e) {
          // Rows stay pending; the next cycle retries.
          await _workerLog(
            db,
            prefs,
            'warn',
            'cloud',
            'Background upload failed',
            detail: '$e',
          );
        }
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      if (borrowedLease) {
        await network.markWorkerPullDone();
      } else if (leased) {
        await network.releaseSyncLease(_workerLeaseOwner);
      }
    }
  });
}

/// Worker isolates are short-lived, so repeat problems are de-duplicated via
/// prefs (same message at most every 30 min) to keep the office log readable.
Future<void> _workerLog(
  AppDatabase db,
  SharedPreferences prefs,
  String level,
  String category,
  String message, {
  String? detail,
}) async {
  try {
    if (level != 'info') {
      const key = 'worker_last_problem';
      const atKey = 'worker_last_problem_at';
      final now = DateTime.now().millisecondsSinceEpoch;
      final same = prefs.getString(key) == message;
      final last = prefs.getInt(atKey) ?? 0;
      if (same && now - last < 30 * 60 * 1000) return;
      await prefs.setString(key, message);
      await prefs.setInt(atKey, now);
    }
    await db.insertAuditLog(
      level: level,
      category: category,
      message: message,
      detail: detail,
    );
  } catch (_) {
    // Logging must never fail the worker.
  }
}

void main() {
  runZonedGuarded(_bootstrap, (error, stack) {
    debugPrint('Uncaught zone error: $error\n$stack');
    _logUncaught('App error', error, stack);
  });
}

final Map<String, DateTime> _uncaughtLoggedAt = {};

/// Sends unexpected errors to the office logs; the same error at most once
/// per 10 minutes so a repeating fault cannot flood the log.
void _logUncaught(String message, Object error, StackTrace? stack) {
  final key = '$message|${error.runtimeType}|${'$error'.split('\n').first}';
  final now = DateTime.now();
  final last = _uncaughtLoggedAt[key];
  if (last != null && now.difference(last) < const Duration(minutes: 10)) {
    return;
  }
  _uncaughtLoggedAt[key] = now;
  final frames = (stack?.toString() ?? '').split('\n').take(8).join('\n');
  unawaited(
    AppDatabase.instance
        .insertAuditLog(
          level: 'error',
          category: 'app',
          message: message,
          detail: '$error\n$frames',
        )
        .catchError((Object _) {}),
  );
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorHandlers();

  final prefs = await SharedPreferences.getInstance();

  // Nothing below may stop the app from opening: each step is best-effort.
  final firebase = FirebaseService();
  try {
    await firebase.initialize().timeout(const Duration(seconds: 10));
  } catch (e) {
    debugPrint('Firebase init skipped: $e');
  }

  try {
    await Workmanager().initialize(callbackDispatcher);
    // Android clamps periodic WorkManager to ~15 min — a backup only. Closed-app
    // sync mainly relies on SiteSyncService (foreground service).
    await Workmanager().registerPeriodicTask(
      AppConstants.syncWorkName,
      AppConstants.syncWorkName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
    await Workmanager().registerPeriodicTask(
      AppConstants.siteSyncWorkName,
      AppConstants.siteSyncWorkName,
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } catch (e) {
    debugPrint('WorkManager setup skipped: $e');
  }

  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      firebaseServiceProvider.overrideWithValue(firebase),
    ],
  );

  final network = container.read(networkServiceProvider);

  // One-time setup: prefer WaterLevel WiFi when nearby + keep background sync alive.
  final siteSyncOn = prefs.getBool(AppConstants.prefsSiteSyncEnabled) ?? true;
  if (siteSyncOn) {
    unawaited(network.suggestGatewayWifi());
    unawaited(network.startSiteSyncService());
    await prefs.setBool(AppConstants.prefsSiteSyncEnabled, true);
  }

  // Do not fire a parallel upload here — AutoSyncController owns the first
  // cycle and overlapping uploads caused "Upload already in progress" errors.

  runApp(
    UncontrolledProviderScope(container: container, child: WaterLevelApp()),
  );
}

/// Errors are logged instead of taking the app down; a broken widget shows a
/// small notice instead of a red/grey screen.
void _installErrorHandlers() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _logUncaught('Screen error', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught platform error: $error\n$stack');
    _logUncaught('App error', error, stack);
    return true;
  };
  if (kReleaseMode) {
    ErrorWidget.builder = (details) => const Material(
      color: Colors.transparent,
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'Part of this screen could not be shown.',
          style: TextStyle(color: Colors.black54, fontSize: 12),
        ),
      ),
    );
  }
}
