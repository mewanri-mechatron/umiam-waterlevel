import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:water_level/core/constants/app_constants.dart';
import 'package:water_level/database/app_database.dart';
import 'package:water_level/models/gateway_models.dart';
import 'package:water_level/models/reading.dart';
import 'package:water_level/services/mock_gateway_service.dart';
import 'package:water_level/services/network_service.dart';
import 'package:water_level/services/firebase_service.dart';
import 'package:water_level/services/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('SQLite duplicate protection and ACK workflow with mock gateway', () async {
    final raw = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          // Reuse production schema by inserting through AppDatabase file API is hard;
          // create minimal schema matching AppDatabase.
          await db.execute('''
CREATE TABLE stations (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  gateway_ip TEXT NOT NULL,
  wifi_ssid TEXT NOT NULL,
  mount_height_mm INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)''');
          await db.execute('''
CREATE TABLE readings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  station_id TEXT NOT NULL,
  boot_id INTEGER NOT NULL,
  seq INTEGER NOT NULL,
  measurement_time INTEGER NOT NULL,
  received_time INTEGER NOT NULL,
  age_seconds INTEGER NOT NULL,
  distance_mm INTEGER,
  water_level_mm INTEGER,
  status INTEGER NOT NULL,
  valid_samples INTEGER NOT NULL,
  send_interval_seconds INTEGER NOT NULL,
  firebase_uploaded INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  is_simulated INTEGER NOT NULL DEFAULT 0,
  UNIQUE(station_id, boot_id, seq)
)''');
          await db.execute('''
CREATE TABLE sync_state (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  station_id TEXT NOT NULL UNIQUE,
  last_download_time INTEGER,
  last_upload_time INTEGER,
  pending_upload_count INTEGER NOT NULL DEFAULT 0,
  last_gateway_contact INTEGER,
  uploaded_count INTEGER NOT NULL DEFAULT 0,
  failed_upload_count INTEGER NOT NULL DEFAULT 0
)''');
          final now = 1_790_000_000;
          await db.insert('stations', {
            'id': AppConstants.defaultStationId,
            'name': AppConstants.defaultStationName,
            'gateway_ip': AppConstants.gatewayIp,
            'wifi_ssid': AppConstants.gatewaySsid,
            'mount_height_mm': 5000,
            'created_at': now,
            'updated_at': now,
          });
          await db.insert('sync_state', {
            'station_id': AppConstants.defaultStationId,
            'pending_upload_count': 0,
            'uploaded_count': 0,
            'failed_upload_count': 0,
          });
        },
      ),
    );

    final appDb = AppDatabase(database: raw);
    final reading = Reading(
      stationId: AppConstants.defaultStationId,
      bootId: 1,
      seq: 1,
      measurementTime: 100,
      receivedTime: 110,
      ageSeconds: 10,
      distanceMm: 1000,
      waterLevelMm: 4000,
      status: 0,
      validSamples: 3,
      sendIntervalSeconds: 30,
      createdAt: 110,
    );

    final first = await appDb.insertReadings([reading]);
    expect(first.inserted.length, 1);
    expect(first.duplicates.length, 0);

    final second = await appDb.insertReadings([reading]);
    expect(second.inserted.length, 0);
    expect(second.duplicates.length, 1);

    final mock = MockGatewayService();
    mock.enqueueScenarioReadings();
    final sync = SyncService(
      database: appDb,
      gateway: mock,
      firebase: FirebaseService(),
      network: NetworkService(),
    );

    final download = await sync.downloadFromGateway();
    expect(download.downloaded, greaterThan(0));
    expect(download.acked, greaterThan(0));

    // Boot restart + wraparound style identities coexist
    final bootChange = Reading(
      stationId: AppConstants.defaultStationId,
      bootId: 2,
      seq: 1,
      measurementTime: 200,
      receivedTime: 210,
      ageSeconds: 10,
      distanceMm: 1100,
      waterLevelMm: 3900,
      status: 0,
      validSamples: 3,
      sendIntervalSeconds: 30,
      createdAt: 210,
    );
    final wrap = Reading(
      stationId: AppConstants.defaultStationId,
      bootId: 2,
      seq: 0xFFFF,
      measurementTime: 220,
      receivedTime: 230,
      ageSeconds: 10,
      distanceMm: 1110,
      waterLevelMm: 3890,
      status: 0,
      validSamples: 3,
      sendIntervalSeconds: 30,
      createdAt: 230,
    );
    final third = await appDb.insertReadings([bootChange, wrap]);
    expect(third.inserted.length, 2);

    await appDb.close();
  });

  test('already uploaded readings are not pending again', () async {
    final raw = await databaseFactory.openDatabase(
      'file:pending_dedupe_${DateTime.now().microsecondsSinceEpoch}?mode=memory&cache=shared',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
CREATE TABLE readings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  station_id TEXT NOT NULL,
  boot_id INTEGER NOT NULL,
  seq INTEGER NOT NULL,
  measurement_time INTEGER NOT NULL,
  received_time INTEGER NOT NULL,
  age_seconds INTEGER NOT NULL,
  distance_mm INTEGER,
  water_level_mm INTEGER,
  status INTEGER NOT NULL,
  valid_samples INTEGER NOT NULL,
  send_interval_seconds INTEGER NOT NULL,
  firebase_uploaded INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  is_simulated INTEGER NOT NULL DEFAULT 0,
  UNIQUE(station_id, boot_id, seq)
)''');
        },
      ),
    );

    final appDb = AppDatabase(database: raw);
    final reading = Reading(
      stationId: AppConstants.defaultStationId,
      bootId: 9,
      seq: 3,
      measurementTime: 100,
      receivedTime: 110,
      ageSeconds: 10,
      distanceMm: 1000,
      waterLevelMm: 4000,
      status: 0,
      validSamples: 3,
      sendIntervalSeconds: 30,
      createdAt: 110,
    );
    await appDb.insertReadings([reading]);
    expect(await appDb.countPending(AppConstants.defaultStationId), 1);

    await appDb.markUploaded([reading]);
    expect(await appDb.countPending(AppConstants.defaultStationId), 0);
    expect(
      await appDb.getPendingUploads(stationId: AppConstants.defaultStationId),
      isEmpty,
    );

    // Re-insert of same identity is treated as duplicate — does not re-queue.
    final again = await appDb.insertReadings([reading]);
    expect(again.duplicates.length, 1);
    expect(await appDb.countPending(AppConstants.defaultStationId), 0);

    await appDb.close();
  });

  test('gateway DTO parsing and ACK payload', () {
    final dto = GatewayReadingDto.fromJson({
      'version': 180,
      'boot_id': 123,
      'seq': 456,
      'age_seconds': 30,
      'distance_mm': 1250,
      'water_level_mm': 3750,
      'status': 0,
      'valid_samples': 3,
      'send_interval_seconds': 30,
    });
    expect(dto.bootId, 123);
    expect(dto.seq, 456);
    final ack = AckRequest(
      stationId: 'station_001',
      records: [(bootId: 123, seq: 456)],
    );
    expect(ack.toJson()['records'], isNotEmpty);
  });
}
