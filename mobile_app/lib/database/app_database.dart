import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/constants/app_constants.dart';
import '../models/reading.dart';
import '../models/station.dart';
import '../models/sync_state.dart';

class CloudSyncInfo {
  const CloudSyncInfo({
    required this.newestLocalTime,
    required this.newestCloudTime,
    required this.oldestPendingTime,
    required this.pendingCount,
  });

  /// Newest reading saved on this phone (epoch seconds).
  final int? newestLocalTime;

  /// Newest reading from this phone confirmed in Firebase.
  final int? newestCloudTime;

  /// Oldest reading still waiting for upload.
  final int? oldestPendingTime;
  final int pendingCount;

  /// How far the cloud trails this phone, in seconds (0 when caught up).
  ///
  /// Always derived from timestamps: newest local − newest uploaded.
  /// Pending count is shown separately; it must not zero out a real lag.
  int get lagSeconds {
    final local = newestLocalTime;
    if (local == null) return 0;
    final cloud = newestCloudTime;
    if (cloud != null) {
      final d = local - cloud;
      return d > 0 ? d : 0;
    }
    // Nothing uploaded yet — lag spans the unsent window on this phone.
    final oldest = oldestPendingTime;
    if (oldest == null) return 0;
    final d = local - oldest;
    return d > 0 ? d : 0;
  }

  /// True when at least one reading is confirmed in Firebase.
  bool get hasCloudData => newestCloudTime != null;
}

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
  Future<Database>? _opening;
  bool _ownsConnection = true;

  /// Concurrent first callers share one open; a failed open can be retried.
  Future<Database> get database async {
    final existing = _db;
    if (existing != null && existing.isOpen) {
      return existing;
    }
    final pending = _opening ??= _open();
    try {
      final db = await pending;
      _db = db;
      return db;
    } finally {
      if (identical(_opening, pending)) _opening = null;
    }
  }

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'water_level.db');
    return openDatabase(
      path,
      version: 5,
      singleInstance: true,
      onConfigure: (db) async {
        // The native uploader writes through its own connection; wait for its
        // short transactions instead of failing with "database is locked".
        await db.rawQuery('PRAGMA busy_timeout = 5000');
      },
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE stations (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  gateway_ip TEXT NOT NULL,
  wifi_ssid TEXT NOT NULL,
  mount_height_mm INTEGER,
  calib_actual_mm INTEGER,
  calib_raw_level_mm INTEGER,
  calib_distance_mm INTEGER,
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
  gateway_record_id INTEGER,
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
  failed_upload_count INTEGER NOT NULL DEFAULT 0,
  last_esp_ack_id INTEGER NOT NULL DEFAULT 0
)
''');
        await _createAuditLogTable(db);

        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        await db.insert('stations', {
          'id': AppConstants.defaultStationId,
          'name': AppConstants.defaultStationName,
          'gateway_ip': AppConstants.gatewayIp,
          'wifi_ssid': AppConstants.gatewaySsid,
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
      onUpgrade: (db, oldVersion, newVersion) => upgradeSchema(db, oldVersion),
    );
  }

  @visibleForTesting
  static Future<void> upgradeSchema(Database db, int oldVersion) async {
    if (oldVersion < 2) {
      await _createAuditLogTable(db);
    }
    if (oldVersion < 3) {
      await db.execute(
        'ALTER TABLE stations ADD COLUMN calib_actual_mm INTEGER',
      );
      await db.execute(
        'ALTER TABLE stations ADD COLUMN calib_raw_level_mm INTEGER',
      );
      await db.execute(
        'ALTER TABLE stations ADD COLUMN calib_distance_mm INTEGER',
      );
    }
    if (oldVersion < 4) {
      final cols = await db.rawQuery('PRAGMA table_info(audit_log)');
      final hasColumn = cols.any((c) => c['name'] == 'cloud_uploaded');
      if (!hasColumn) {
        await db.execute(
          'ALTER TABLE audit_log ADD COLUMN cloud_uploaded INTEGER NOT NULL DEFAULT 0',
        );
        // Older lines stay on the phone only; send from this version on.
        await db.execute('UPDATE audit_log SET cloud_uploaded = 1');
      }
    }
    if (oldVersion < 5) {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      );
      final names = tables.map((t) => t['name']).toSet();
      if (names.contains('readings')) {
        final readingCols = await db.rawQuery('PRAGMA table_info(readings)');
        if (!readingCols.any((c) => c['name'] == 'gateway_record_id')) {
          await db.execute(
            'ALTER TABLE readings ADD COLUMN gateway_record_id INTEGER',
          );
        }
      }
      if (names.contains('sync_state')) {
        final syncCols = await db.rawQuery('PRAGMA table_info(sync_state)');
        if (!syncCols.any((c) => c['name'] == 'last_esp_ack_id')) {
          await db.execute(
            'ALTER TABLE sync_state ADD COLUMN last_esp_ack_id INTEGER NOT NULL DEFAULT 0',
          );
        }
      }
    }
  }

  /// Highest ESP queue id we can safely delete: every local reading with a
  /// lower-or-equal gateway id is already in the cloud. Never advances past
  /// an unsent reading, so the ESP keeps anything the office does not have.
  Future<int?> safeEspAckUpTo(String stationId) async {
    final db = await database;
    final pendingMin = await db.rawQuery(
      '''
SELECT MIN(gateway_record_id) AS m FROM readings
WHERE station_id = ? AND gateway_record_id IS NOT NULL
  AND firebase_uploaded = 0 AND is_simulated = 0
''',
      [stationId],
    );
    final minPending = pendingMin.first['m'] as int?;
    if (minPending != null) {
      final upTo = minPending - 1;
      return upTo > 0 ? upTo : null;
    }
    final uploadedMax = await db.rawQuery(
      '''
SELECT MAX(gateway_record_id) AS m FROM readings
WHERE station_id = ? AND gateway_record_id IS NOT NULL
  AND firebase_uploaded = 1
''',
      [stationId],
    );
    return uploadedMax.first['m'] as int?;
  }

  Future<int> lastEspAckId(String stationId) async {
    final sync = await getSyncState(stationId);
    return sync.lastEspAckId;
  }

  Future<void> setLastEspAckId(String stationId, int upTo) async {
    final sync = await getSyncState(stationId);
    if (upTo == sync.lastEspAckId) return;
    // Absolute set so a gateway id wrap/reset can move the watermark down.
    await updateSyncState(sync.copyWith(lastEspAckId: upTo));
  }

  static Future<void> _createAuditLogTable(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at INTEGER NOT NULL,
  level TEXT NOT NULL,
  category TEXT NOT NULL,
  message TEXT NOT NULL,
  detail TEXT,
  cloud_uploaded INTEGER NOT NULL DEFAULT 0
)
''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_log(created_at DESC)',
    );
  }

  Future<void> insertAuditLog({
    required String level,
    required String category,
    required String message,
    String? detail,
  }) async {
    final db = await database;
    await db.insert('audit_log', {
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'level': level,
      'category': category,
      'message': message,
      'detail': detail,
    });
    // Keep a long local trail for field debugging; prune occasionally.
    if (++_auditInsertsSincePrune >= 100) {
      _auditInsertsSincePrune = 0;
      await db.rawDelete(
        'DELETE FROM audit_log WHERE id NOT IN '
        '(SELECT id FROM audit_log ORDER BY id DESC LIMIT 5000)',
      );
    }
  }

  int _auditInsertsSincePrune = 100;

  Future<List<Map<String, Object?>>> getAuditLogs({int limit = 2000}) async {
    final db = await database;
    return db.query(
      'audit_log',
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  Future<void> clearAuditLogs() async {
    final db = await database;
    await db.delete('audit_log');
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
    final inserted = <Reading>[];
    final duplicates = <Reading>[];
    if (readings.isEmpty) return (inserted: inserted, duplicates: duplicates);
    final db = await database;

    // One batched INSERT OR IGNORE per chunk: a single platform round-trip and
    // a short write lock, instead of two round-trips per row.
    const chunk = 500;
    for (var start = 0; start < readings.length; start += chunk) {
      final part = readings.sublist(
        start,
        start + chunk > readings.length ? readings.length : start + chunk,
      );
      final results = await db.transaction((txn) async {
        final batch = txn.batch();
        for (final reading in part) {
          batch.insert(
            'readings',
            reading.toMap()..remove('id'),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        return batch.commit();
      });
      for (var i = 0; i < part.length; i++) {
        final id = i < results.length ? results[i] : null;
        if (id is int && id > 0) {
          inserted.add(part[i].copyWith(id: id));
        } else {
          duplicates.add(part[i]);
        }
      }
    }

    // Re-downloads of rows already on the phone: fill in the ESP queue id so
    // we can ACK them later once they reach the cloud.
    for (final reading in duplicates) {
      final gid = reading.gatewayRecordId;
      if (gid == null) continue;
      await db.update(
        'readings',
        {'gateway_record_id': gid},
        where:
            'station_id = ? AND boot_id = ? AND seq = ? AND gateway_record_id IS NULL',
        whereArgs: [reading.stationId, reading.bootId, reading.seq],
      );
    }

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
      final batch = txn.batch();
      for (final r in readings) {
        batch.update(
          'readings',
          {'firebase_uploaded': 1},
          where: 'station_id = ? AND boot_id = ? AND seq = ?',
          whereArgs: [r.stationId, r.bootId, r.seq],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Phone-vs-cloud picture from local rows only (no network needed).
  Future<CloudSyncInfo> getCloudSyncInfo(String stationId) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
SELECT
  MAX(measurement_time) AS newest_local,
  MAX(CASE WHEN firebase_uploaded = 1 THEN measurement_time END) AS newest_cloud,
  MIN(CASE WHEN firebase_uploaded = 0 AND is_simulated = 0 THEN measurement_time END) AS oldest_pending,
  SUM(CASE WHEN firebase_uploaded = 0 AND is_simulated = 0 THEN 1 ELSE 0 END) AS pending
FROM readings WHERE station_id = ?
''',
      [stationId],
    );
    final row = rows.isEmpty ? const <String, Object?>{} : rows.first;
    int? asInt(Object? v) => v is num ? v.toInt() : null;
    return CloudSyncInfo(
      newestLocalTime: asInt(row['newest_local']),
      newestCloudTime: asInt(row['newest_cloud']),
      oldestPendingTime: asInt(row['oldest_pending']),
      pendingCount: asInt(row['pending']) ?? 0,
    );
  }

  /// Retention: drop old rows that are already safe in the cloud. Rows still
  /// waiting for upload are never deleted.
  Future<int> deleteUploadedReadingsBefore({
    required String stationId,
    required int beforeEpoch,
  }) async {
    final db = await database;
    return db.delete(
      'readings',
      where: 'station_id = ? AND measurement_time < ? AND firebase_uploaded = 1',
      whereArgs: [stationId, beforeEpoch],
    );
  }

  /// Recreates the default station row if it was ever lost.
  Future<Station> ensureDefaultStation() async {
    final existing = await getStation(AppConstants.defaultStationId);
    if (existing != null) return existing;
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.insert(
      'stations',
      {
        'id': AppConstants.defaultStationId,
        'name': AppConstants.defaultStationName,
        'gateway_ip': AppConstants.gatewayIp,
        'wifi_ssid': AppConstants.gatewaySsid,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return (await getStation(AppConstants.defaultStationId))!;
  }

  Future<int> countPending(String stationId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM readings WHERE station_id = ? AND firebase_uploaded = 0 AND is_simulated = 0',
      [stationId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> countReadings(String stationId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM readings WHERE station_id = ?',
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
