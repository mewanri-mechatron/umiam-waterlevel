import 'dart:io';

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

  test('safe ESP ACK never passes an unsent gateway id', () async {
    final path =
        '${Directory.systemTemp.path}/umiam_esp_ack_${DateTime.now().microsecondsSinceEpoch}.db';
    await databaseFactory.deleteDatabase(path);
    final raw = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 5,
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
  gateway_record_id INTEGER,
  UNIQUE(station_id, boot_id, seq)
)
''');
          await db.execute('''
CREATE TABLE sync_state (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  station_id TEXT NOT NULL UNIQUE,
  last_esp_ack_id INTEGER NOT NULL DEFAULT 0
)
''');
          await db.insert('sync_state', {
            'station_id': AppConstants.defaultStationId,
            'last_esp_ack_id': 0,
          });
        },
      ),
    );
    final appDb = AppDatabase(database: raw);
    Future<void> row(int gid, {required bool uploaded}) async {
      await raw.insert('readings', {
        'station_id': AppConstants.defaultStationId,
        'boot_id': 1,
        'seq': gid,
        'measurement_time': gid,
        'received_time': gid,
        'age_seconds': 0,
        'status': 0,
        'valid_samples': 1,
        'send_interval_seconds': 3600,
        'firebase_uploaded': uploaded ? 1 : 0,
        'created_at': gid,
        'is_simulated': 0,
        'gateway_record_id': gid,
      });
    }

    await row(10, uploaded: true);
    await row(11, uploaded: true);
    await row(12, uploaded: false);
    expect(await appDb.safeEspAckUpTo(AppConstants.defaultStationId), 11);

    await raw.update(
      'readings',
      {'firebase_uploaded': 1},
      where: 'gateway_record_id = 12',
    );
    expect(await appDb.safeEspAckUpTo(AppConstants.defaultStationId), 12);
    await raw.close();
  });

  test('v3 → v4 upgrade keeps old logs local and sends new ones', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
CREATE TABLE audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at INTEGER NOT NULL,
  level TEXT NOT NULL,
  category TEXT NOT NULL,
  message TEXT NOT NULL,
  detail TEXT
)
''');
    await db.insert('audit_log', {
      'created_at': 1,
      'level': 'info',
      'category': 'app',
      'message': 'old line',
    });

    await AppDatabase.upgradeSchema(db, 3);
    // Running it twice (interrupted upgrade) must not fail.
    await AppDatabase.upgradeSchema(db, 3);

    await db.insert('audit_log', {
      'created_at': 2,
      'level': 'warn',
      'category': 'app',
      'message': 'new line',
    });
    final rows = await db.query('audit_log', orderBy: 'id');
    expect(rows.map((r) => r['cloud_uploaded']), [1, 0]);
    await db.close();
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
  gateway_record_id INTEGER,
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
  failed_upload_count INTEGER NOT NULL DEFAULT 0,
  last_esp_ack_id INTEGER NOT NULL DEFAULT 0
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
            'last_esp_ack_id': 0,
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
    // Unsent readings must stay on the ESP until the cloud has them.
    expect(download.acked, 0);
    expect(download.message, contains('sensor keeps queue'));

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

  test('retention never deletes unsent readings; cloud lag is computed', () async {
    final raw = await databaseFactory.openDatabase(
      'file:retention_${DateTime.now().microsecondsSinceEpoch}?mode=memory&cache=shared',
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
    Reading at(int seq, int time, {bool uploaded = false}) => Reading(
          stationId: AppConstants.defaultStationId,
          bootId: 1,
          seq: seq,
          measurementTime: time,
          receivedTime: time,
          ageSeconds: 0,
          distanceMm: 1000,
          waterLevelMm: 4000,
          status: 0,
          validSamples: 3,
          sendIntervalSeconds: 900,
          firebaseUploaded: uploaded,
          createdAt: time,
        );

    await appDb.insertReadings([
      at(1, 1000, uploaded: true),
      at(2, 2000), // old but never sent
      at(3, 5000, uploaded: true),
      at(4, 8600),
    ]);

    final info = await appDb.getCloudSyncInfo(AppConstants.defaultStationId);
    expect(info.newestLocalTime, 8600);
    expect(info.newestCloudTime, 5000);
    expect(info.oldestPendingTime, 2000);
    expect(info.pendingCount, 2);
    expect(info.hasCloudData, isTrue);
    // Cloud newest is 5000, phone newest is 8600 → 3600s behind.
    expect(info.lagSeconds, 3600);

    await appDb.insertReadings([
      at(5, 8600 + 900, uploaded: true),
    ]);
    final caughtUp =
        await appDb.getCloudSyncInfo(AppConstants.defaultStationId);
    // Newest local still has older pending rows, so lag stays until those upload.
    expect(caughtUp.newestLocalTime, 8600 + 900);
    expect(caughtUp.newestCloudTime, 8600 + 900);
    expect(caughtUp.lagSeconds, 0);

    final removed = await appDb.deleteUploadedReadingsBefore(
      stationId: AppConstants.defaultStationId,
      beforeEpoch: 6000,
    );
    expect(removed, 2);
    expect(await appDb.countPending(AppConstants.defaultStationId), 2);

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
