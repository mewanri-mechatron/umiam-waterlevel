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

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final useMock = prefs.getBool(AppConstants.prefsUseMockGateway) ?? false;
      final reason = inputData?['reason'] as String? ?? 'all';
      // Shared singleton — never close from a background isolate.
      final db = AppDatabase.instance;
      final network = NetworkService();
      final firebase = FirebaseService();
      await firebase.initialize();
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

      // Near ESP SoftAP → pull buffered readings (SiteSync binds SoftAP first).
      if (doPull && (onGateway || useMock)) {
        try {
          if (onGateway) {
            await network.bindToGatewayNetwork();
          }
          await sync.downloadFromGateway();
        } catch (_) {
          // SoftAP may drop; retry on next tick.
        }
      }

      // Cloud upload — SiteSyncService binds LTE before "upload" jobs.
      if (doUpload) {
        await network.bindToInternetNetwork();
        // Attempt whenever this is an upload tick; native bind may already
        // have switched the process off SoftAP onto cellular.
        await sync.uploadPendingToFirebase();
      }
      return true;
    } catch (_) {
      return false;
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  final firebase = FirebaseService();
  await firebase.initialize();

  await Workmanager().initialize(callbackDispatcher);

  // Android clamps periodic WorkManager to ~15 min minimum — useful as a
  // backup only. Closed-app sync mainly relies on SiteSyncService (FGS),
  // which enqueues a one-shot Flutter worker about once a minute.
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
    // ignore: unawaited_futures
    network.suggestGatewayWifi();
    // ignore: unawaited_futures
    network.startSiteSyncService();
    await prefs.setBool(AppConstants.prefsSiteSyncEnabled, true);
  }

  // Do not fire a parallel upload here — AutoSyncController owns the first
  // cycle and overlapping uploads caused "Upload already in progress" errors.

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: WaterLevelApp(),
    ),
  );
}
