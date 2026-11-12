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

      // Near ESP SoftAP → pull buffered readings.
      final onGateway = await network.isConnectedToGatewayWifi();
      if (onGateway || useMock) {
        try {
          if (onGateway) {
            await network.bindToGatewayNetwork();
          }
          await sync.downloadFromGateway();
        } catch (_) {
          // SoftAP may drop; retry on next tick.
        } finally {
          if (onGateway) {
            await network.clearNetworkBinding();
          }
        }
      }

      // Normal internet → push pending readings to Firebase.
      if (await network.hasInternet()) {
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

  // Upload path when online.
  await Workmanager().registerPeriodicTask(
    AppConstants.syncWorkName,
    AppConstants.syncWorkName,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );

  // Site path: also runs without internet so SoftAP pulls can happen.
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

  if (await network.hasInternet()) {
    // ignore: unawaited_futures
    container.read(syncServiceProvider).uploadPendingToFirebase();
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: WaterLevelApp(),
    ),
  );
}
