import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/constants/app_constants.dart';
import '../models/reading.dart';
import '../models/station.dart';
import '../models/sync_state.dart';

class AppDatabase {
  AppDatabase._();

  /// Shared app database. Never close this from background workers while the
  /// UI isolate may still be using the same SQLite file.
  static final AppDatabase instance = AppDatabase._();

  /// Test helper — inject an already-opened database.
  factory AppDatabase({Database? database}) {
    if (database != null) {
      final db = AppDatabase._();
      db._db = database;
      db._ownsConnection = false;
      return db;
    }
    return instance;
  }

  Database? _db;
  bool _ownsConnection = true;

  Future<Database> get database async {
    final existing = _db;
    if (existing != null && existing.isOpen) {
      return existing;
    }
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'water_level.db');
    return openDatabase(
      path,
      version: 1,
      singleInstance: true,
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE stations (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  gateway_ip TEXT NOT NULL,
  wifi_ssid TEXT NOT NULL,
  mount_height_mm INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
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
)
''');
        await db.execute(
          'CREATE INDEX idx_readings_station_time ON readings(station_id, measurement_time DESC)',
        );
        await db.execute(
          'CREATE INDEX idx_readings_pending ON readings(station_id, firebase_uploaded)',
        );
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
)
''');

        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
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
    );
  }

  Future<Station?> getStation(String id) async {
    final db = await database;
    final rows = await db.query('stations', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Station.fromMap(rows.first);
  }

  Future<void> upsertStation(Station station) async {
    final db = await database;
    await db.insert(
      'stations',
      station.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<SyncState> getSyncState(String stationId) async {
    final db = await database;
    final rows = await db.query(
      'sync_state',
      where: 'station_id = ?',
      whereArgs: [stationId],
    );
    if (rows.isEmpty) {
      final state = SyncState(stationId: stationId);
      final id = await db.insert('sync_state', state.toMap());
      return SyncState(id: id, stationId: stationId);
    }
    return SyncState.fromMap(rows.first);
  }

  Future<void> updateSyncState(SyncState state) async {
    final db = await database;
    await db.insert(
      'sync_state',
      state.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<({List<Reading> inserted, List<Reading> duplicates})> insertReadings(
    List<Reading> readings,
  ) async {
    final db = await database;
    final inserted = <Reading>[];
    final duplicates = <Reading>[];

    await db.transaction((txn) async {
      for (final reading in readings) {
        final existing = await txn.query(
          'readings',
          columns: ['id'],
          where: 'station_id = ? AND boot_id = ? AND seq = ?',
          whereArgs: [reading.stationId, reading.bootId, reading.seq],
        );
        if (existing.isNotEmpty) {
          duplicates.add(reading);
          continue;
        }
        final id = await txn.insert('readings', reading.toMap()..remove('id'));
        inserted.add(reading.copyWith(id: id));
      }
    });

    return (inserted: inserted, duplicates: duplicates);
  }

  Future<List<Reading>> getReadings({
    required String stationId,
    int? fromEpoch,
    int? toEpoch,
    int? limit,
  }) async {
    final db = await database;
    final where = StringBuffer('station_id = ?');
    final args = <Object?>[stationId];
    if (fromEpoch != null) {
      where.write(' AND measurement_time >= ?');
      args.add(fromEpoch);
    }
    if (toEpoch != null) {
      where.write(' AND measurement_time <= ?');
      args.add(toEpoch);
    }
    return (await db.query(
      'readings',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'measurement_time DESC',
      limit: limit,
    ))
        .map(Reading.fromMap)
        .toList();
  }

  Future<Reading?> getLatestReading(String stationId) async {
    final rows = await getReadings(stationId: stationId, limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Reading>> getPendingUploads({
    required String stationId,
    int limit = 50,
  }) async {
    final db = await database;
    final rows = await db.query(
      'readings',
      where: 'station_id = ? AND firebase_uploaded = 0 AND is_simulated = 0',
      whereArgs: [stationId],
      orderBy: 'measurement_time ASC',
      limit: limit,
    );
    return rows.map(Reading.fromMap).toList();
  }

  Future<void> markUploaded(List<Reading> readings) async {
    if (readings.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (final r in readings) {
        await txn.update(
          'readings',
          {'firebase_uploaded': 1},
          where: 'station_id = ? AND boot_id = ? AND seq = ?',
          whereArgs: [r.stationId, r.bootId, r.seq],
        );
      }
    });
  }

  Future<int> countPending(String stationId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM readings WHERE station_id = ? AND firebase_uploaded = 0 AND is_simulated = 0',
      [stationId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Only for tests. Do not close the shared instance from WorkManager.
  Future<void> close() async {
    if (!_ownsConnection) {
      _db = null;
      return;
    }
    // Keep the shared singleton usable; clearing the handle is enough for tests
    // that injected their own connection.
    if (!identical(this, instance)) {
      await _db?.close();
    }
    _db = null;
  }
}
