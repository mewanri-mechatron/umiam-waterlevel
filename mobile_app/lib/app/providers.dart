import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../database/app_database.dart';
import '../models/reading.dart';
import '../models/station.dart';
import '../models/sync_state.dart';
import '../repositories/reading_repository.dart';
import '../repositories/station_repository.dart';
import '../services/audit_log_service.dart';
import '../services/auto_sync_controller.dart';
import '../services/firebase_service.dart';
import '../services/gateway_client.dart';
import '../services/http_gateway_service.dart';
import '../services/mock_gateway_service.dart';
import '../services/network_service.dart';
import '../services/sync_service.dart';

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('SharedPreferences must be overridden in main');
});

final appDatabaseProvider = Provider<AppDatabase>((ref) => AppDatabase.instance);

final networkServiceProvider = Provider<NetworkService>((ref) => NetworkService());

final firebaseServiceProvider = Provider<FirebaseService>((ref) => FirebaseService());

final useMockGatewayProvider =
    StateNotifierProvider<UseMockGatewayNotifier, bool>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return UseMockGatewayNotifier(prefs);
});

class UseMockGatewayNotifier extends StateNotifier<bool> {
  UseMockGatewayNotifier(this._prefs)
      : super(_prefs.getBool(AppConstants.prefsUseMockGateway) ?? false);

  final SharedPreferences _prefs;

  Future<void> setUseMock(bool value) async {
    state = value;
    await _prefs.setBool(AppConstants.prefsUseMockGateway, value);
  }
}

final mockGatewayProvider = Provider<MockGatewayService>((ref) {
  return MockGatewayService();
});

final gatewayClientProvider = Provider<GatewayClient>((ref) {
  final useMock = ref.watch(useMockGatewayProvider);
  if (useMock) return ref.watch(mockGatewayProvider);
  return HttpGatewayService(networkService: ref.watch(networkServiceProvider));
});

final syncServiceProvider = Provider<SyncService>((ref) {
  final service = SyncService(
    database: ref.watch(appDatabaseProvider),
    gateway: ref.watch(gatewayClientProvider),
    firebase: ref.watch(firebaseServiceProvider),
    network: ref.watch(networkServiceProvider),
  );
  ref.listen<GatewayClient>(gatewayClientProvider, (_, next) {
    service.updateGateway(next);
  });
  return service;
});

final auditLogServiceProvider = ChangeNotifierProvider<AuditLogService>((ref) {
  return AuditLogService(ref.watch(appDatabaseProvider));
});

final autoSyncControllerProvider =
    ChangeNotifierProvider<AutoSyncController>((ref) {
  // IMPORTANT: use ref.read for dependencies. Watching ChangeNotifiers
  // (especially audit log) was recreating+disposing this controller on every
  // log line, which froze the home UI on Idle/Ready.
  final db = ref.read(appDatabaseProvider);
  final controller = AutoSyncController(
    syncService: ref.read(syncServiceProvider),
    networkService: ref.read(networkServiceProvider),
    auditLog: ref.read(auditLogServiceProvider),
    isDemoMode: () => ref.read(useMockGatewayProvider),
    pendingCountLoader: () => db.countPending(AppConstants.defaultStationId),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final stationRepositoryProvider = Provider<StationRepository>((ref) {
  return StationRepository(ref.watch(appDatabaseProvider));
});

final readingRepositoryProvider = Provider<ReadingRepository>((ref) {
  return ReadingRepository(ref.watch(appDatabaseProvider));
});

final stationProvider = FutureProvider<Station>((ref) async {
  return ref.watch(stationRepositoryProvider).getDefaultStation();
});

final dashboardDataProvider =
    AsyncNotifierProvider<DashboardDataNotifier, DashboardData>(
  DashboardDataNotifier.new,
);

class DashboardData {
  const DashboardData({
    required this.station,
    required this.latest,
    required this.recent,
    required this.syncState,
    required this.pendingCount,
    required this.hasInternet,
    required this.onGatewayWifi,
    required this.usingMockGateway,
  });

  final Station station;
  final Reading? latest;
  final List<Reading> recent;
  final SyncState syncState;
  final int pendingCount;
  final bool hasInternet;
  final bool onGatewayWifi;
  final bool usingMockGateway;
}

class DashboardDataNotifier extends AsyncNotifier<DashboardData> {
  @override
  Future<DashboardData> build() => _load();

  Future<DashboardData> _load() async {
    final db = ref.read(appDatabaseProvider);
    final network = ref.read(networkServiceProvider);
    final station =
        await ref.read(stationRepositoryProvider).getDefaultStation();
    final latest = await db.getLatestReading(station.id);
    final recent = await db.getReadings(stationId: station.id, limit: 48);
    final sync = await db.getSyncState(station.id);
    final pending = await db.countPending(station.id);

    // Peek only — never rebind SoftAP away during a dashboard reload.
    final online = await network.peekHasInternet().timeout(
      const Duration(seconds: 1),
      onTimeout: () => false,
    );
    final onGateway = await network.isOnGatewayFast().timeout(
      const Duration(seconds: 1),
      onTimeout: () => false,
    );

    return DashboardData(
      station: station,
      latest: latest,
      recent: recent.reversed.toList(),
      syncState: sync,
      pendingCount: pending,
      hasInternet: online,
      onGatewayWifi: onGateway,
      usingMockGateway: ref.read(useMockGatewayProvider),
    );
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(_load);
  }
}

final historyFilterProvider =
    StateProvider<HistoryFilter>((ref) => HistoryFilter.last24h);

enum HistoryFilter { last24h, last7d, last30d, all, custom }

class HistoryQuery {
  const HistoryQuery({this.from, this.to});
  final DateTime? from;
  final DateTime? to;
}

final customHistoryRangeProvider = StateProvider<HistoryQuery>((ref) {
  return const HistoryQuery();
});

final historyReadingsProvider = FutureProvider<List<Reading>>((ref) async {
  final filter = ref.watch(historyFilterProvider);
  final custom = ref.watch(customHistoryRangeProvider);
  final now = DateTime.now();
  int? from;
  int? to = now.millisecondsSinceEpoch ~/ 1000;
  switch (filter) {
    case HistoryFilter.last24h:
      from = now.subtract(const Duration(hours: 24)).millisecondsSinceEpoch ~/
          1000;
      break;
    case HistoryFilter.last7d:
      from = now.subtract(const Duration(days: 7)).millisecondsSinceEpoch ~/
          1000;
      break;
    case HistoryFilter.last30d:
      from = now.subtract(const Duration(days: 30)).millisecondsSinceEpoch ~/
          1000;
      break;
    case HistoryFilter.all:
      from = null;
      to = null;
      break;
    case HistoryFilter.custom:
      from = custom.from?.millisecondsSinceEpoch != null
          ? custom.from!.millisecondsSinceEpoch ~/ 1000
          : null;
      to = custom.to?.millisecondsSinceEpoch != null
          ? custom.to!.millisecondsSinceEpoch ~/ 1000
          : null;
      break;
  }
  return ref.read(readingRepositoryProvider).history(
        stationId: AppConstants.defaultStationId,
        fromEpoch: from,
        toEpoch: to,
      );
});
