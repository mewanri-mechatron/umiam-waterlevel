import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../core/constants/firebase_options_stub.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/water_level_math.dart';
import '../models/reading.dart';
import '../models/station.dart';

class FirebaseService {
  FirebaseService({FirebaseAuth? auth, FirebaseDatabase? database}) {
    _auth = auth;
    _database = database;
  }

  FirebaseAuth? _auth;
  FirebaseDatabase? _database;
  bool _initialized = false;

  // The Firebase SDK never times out on its own: offline writes and reads can
  // wait forever, which used to freeze sync cycles.
  static const _authTimeout = Duration(seconds: 20);
  static const _readTimeout = Duration(seconds: 25);
  static const _writeTimeout = Duration(seconds: 30);

  bool get isConfigured => DefaultFirebaseOptions.isConfigured;
  bool get isInitialized => _initialized;

  Future<bool> initialize() async {
    if (!isConfigured) {
      _initialized = false;
      return false;
    }
    if (_initialized) return true;
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    _auth ??= FirebaseAuth.instance;
    // Explicit RTDB URL — required for non-default / regional databases.
    _database ??= FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: DefaultFirebaseOptions.currentPlatform.databaseURL,
    );
    _initialized = true;
    return true;
  }

  Future<void> ensureSignedIn() async {
    if (!_initialized || _auth == null) {
      throw SyncException('Firebase is not configured on this device.');
    }
    if (_auth!.currentUser == null) {
      try {
        await _auth!.signInAnonymously().timeout(_authTimeout);
      } catch (e) {
        throw SyncException(
          'Firebase Anonymous Auth failed. Enable Anonymous sign-in '
          'in Firebase Console → Authentication. ($e)',
        );
      }
    }
  }

  Future<bool> isConnected() async {
    if (!_initialized || _database == null) return false;
    try {
      final snap = await _database!
          .ref('.info/connected')
          .get()
          .timeout(const Duration(seconds: 5));
      return snap.value == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> upsertStation(Station station) async {
    await ensureSignedIn();
    await _database!
        .ref('water/stations/${station.id}')
        .update({
          'name': station.name,
          if (station.calibActualMm != null)
            'calib_actual_mm': station.calibActualMm,
          if (station.calibRawLevelMm != null)
            'calib_raw_level_mm': station.calibRawLevelMm,
          if (station.calibDistanceMm != null)
            'calib_distance_mm': station.calibDistanceMm,
          'last_updated': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        })
        .timeout(_writeTimeout);
  }

  /// Station metadata from cloud (calibration snapshot).
  Future<
    ({
      String? name,
      int? calibActualMm,
      int? calibRawLevelMm,
      int? calibDistanceMm,
    })?
  >
  fetchStationMeta(String stationId) async {
    await ensureSignedIn();
    final snap = await _database!
        .ref('water/stations/$stationId')
        .get()
        .timeout(_readTimeout);
    if (!snap.exists || snap.value is! Map) return null;
    final map = Map<Object?, Object?>.from(snap.value as Map);
    return (
      name: map['name'] as String?,
      calibActualMm: (map['calib_actual_mm'] as num?)?.toInt(),
      calibRawLevelMm: (map['calib_raw_level_mm'] as num?)?.toInt(),
      calibDistanceMm: (map['calib_distance_mm'] as num?)?.toInt(),
    );
  }

  /// Readings previously uploaded by this (or another) phone, newest first.
  /// [sinceEpoch] bounds the download so it never pulls the whole history.
  Future<List<Reading>> fetchReadings({
    required String stationId,
    int? sinceEpoch,
    int limit = 5000,
  }) async {
    await ensureSignedIn();
    final rootRef = _database!.ref('water/readings/$stationId');
    DataSnapshot snap;
    try {
      Query query = rootRef;
      if (sinceEpoch != null) {
        query = query.orderByChild('measurement_time').startAt(sinceEpoch);
      }
      snap = await query.limitToLast(limit).get().timeout(_readTimeout);
    } catch (e) {
      // Index can lag a few minutes after rules deploy. Fall back to a plain
      // fetch and filter on the phone so restore still works.
      final msg = e.toString();
      if (!msg.contains('index-not-defined') && !msg.contains('Index not defined')) {
        rethrow;
      }
      snap = await rootRef.get().timeout(_readTimeout);
    }
    if (!snap.exists || snap.value is! Map) return const [];
    final root = Map<Object?, Object?>.from(snap.value as Map);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final out = <Reading>[];
    for (final entry in root.entries) {
      if (entry.value is! Map) continue;
      final map = Map<Object?, Object?>.from(entry.value as Map);
      final reading = Reading.fromFirebaseMap(
        stationId: stationId,
        map: map,
        createdAt: now,
      );
      if (reading.bootId == 0 &&
          reading.seq == 0 &&
          reading.measurementTime == 0) {
        continue;
      }
      if (sinceEpoch != null && reading.measurementTime < sinceEpoch) continue;
      out.add(reading);
    }
    out.sort((a, b) => b.measurementTime.compareTo(a.measurementTime));
    if (out.length > limit) return out.sublist(0, limit);
    return out;
  }

  /// Field phones that have reported status to `water/devices`.
  Future<List<CloudPhoneInfo>> fetchDevices() async {
    await ensureSignedIn();
    final snap = await _database!
        .ref('water/devices')
        .get()
        .timeout(_readTimeout);
    if (!snap.exists || snap.value is! Map) return const [];
    final root = Map<Object?, Object?>.from(snap.value as Map);
    final out = <CloudPhoneInfo>[];
    for (final entry in root.entries) {
      if (entry.value is! Map) continue;
      final map = Map<Object?, Object?>.from(entry.value as Map);
      final id = map['device_id']?.toString() ?? entry.key.toString();
      if (id.isEmpty) continue;
      out.add(
        CloudPhoneInfo(
          deviceId: id,
          name: map['name']?.toString() ?? map['model']?.toString() ?? id,
          model: map['model']?.toString() ?? '',
          appVersion: map['app_version']?.toString() ?? '',
          lastSeenMs:
              (map['last_seen'] as num?)?.toInt() ??
              (map['last_seen_phone'] as num?)?.toInt() ??
              0,
          readingsWaiting: (map['readings_waiting'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    out.sort((a, b) => b.lastSeenMs.compareTo(a.lastSeenMs));
    return out;
  }

  /// Recent audit lines for one phone from `water/logs/{deviceId}`.
  Future<List<CloudLogEntry>> fetchDeviceLogs(
    String deviceId, {
    int limit = 300,
  }) async {
    await ensureSignedIn();
    final snap = await _database!
        .ref('water/logs/$deviceId')
        .orderByChild('created_at')
        .limitToLast(limit)
        .get()
        .timeout(_readTimeout);
    if (!snap.exists || snap.value is! Map) return const [];
    final root = Map<Object?, Object?>.from(snap.value as Map);
    final out = <CloudLogEntry>[];
    for (final entry in root.entries) {
      if (entry.value is! Map) continue;
      final map = Map<Object?, Object?>.from(entry.value as Map);
      final createdAt = (map['created_at'] as num?)?.toInt() ?? 0;
      if (createdAt <= 0) continue;
      out.add(
        CloudLogEntry(
          createdAtMs: createdAt,
          level: map['level']?.toString() ?? 'info',
          category: map['category']?.toString() ?? 'app',
          message: map['message']?.toString() ?? '',
          detail: map['detail']?.toString(),
        ),
      );
    }
    out.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return out;
  }

  Future<void> uploadReadings({
    required Station station,
    required List<Reading> readings,
  }) async {
    if (readings.isEmpty) return;
    await ensureSignedIn();
    final uploadedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final updates = <String, Object?>{};

    for (final reading in readings) {
      updates['water/readings/${station.id}/${reading.firebaseKey}'] = reading
          .toFirebaseMap(
            uploadedAt: uploadedAt,
            calibActualMm: station.calibActualMm,
            calibRawLevelMm: station.calibRawLevelMm,
            calibDistanceMm: station.calibDistanceMm,
          );
    }

    final latestSnap = await _database!
        .ref('water/latest/${station.id}')
        .get()
        .timeout(_readTimeout);
    var newest = readings.first;
    for (final r in readings.skip(1)) {
      if (compareReadingRecency(
            aMeasurementTime: r.measurementTime,
            aBootId: r.bootId,
            aSeq: r.seq,
            bMeasurementTime: newest.measurementTime,
            bBootId: newest.bootId,
            bSeq: newest.seq,
          ) >
          0) {
        newest = r;
      }
    }

    var shouldUpdateLatest = true;
    if (latestSnap.exists && latestSnap.value is Map) {
      final map = Map<Object?, Object?>.from(latestSnap.value as Map);
      final currentTime = (map['measurement_time'] as num?)?.toInt() ?? 0;
      final currentBoot = (map['boot_id'] as num?)?.toInt() ?? 0;
      final currentSeq = (map['seq'] as num?)?.toInt() ?? 0;
      shouldUpdateLatest =
          compareReadingRecency(
            aMeasurementTime: newest.measurementTime,
            aBootId: newest.bootId,
            aSeq: newest.seq,
            bMeasurementTime: currentTime,
            bBootId: currentBoot,
            bSeq: currentSeq,
          ) >
          0;
    }

    if (shouldUpdateLatest) {
      updates['water/latest/${station.id}'] = {
        ...newest.toFirebaseMap(
          uploadedAt: uploadedAt,
          calibActualMm: station.calibActualMm,
          calibRawLevelMm: station.calibRawLevelMm,
          calibDistanceMm: station.calibDistanceMm,
        ),
      };
    }

    // Full station node required: rules validate `name` on every write.
    // Writing only `last_updated` fails when the station does not exist yet,
    // and that aborts the entire multi-path update (readings never land).
    updates['water/stations/${station.id}'] = {
      'name': station.name,
      if (station.calibActualMm != null)
        'calib_actual_mm': station.calibActualMm,
      if (station.calibRawLevelMm != null)
        'calib_raw_level_mm': station.calibRawLevelMm,
      if (station.calibDistanceMm != null)
        'calib_distance_mm': station.calibDistanceMm,
      'last_updated': uploadedAt,
    };
    await _database!.ref().update(updates).timeout(_writeTimeout);
  }
}

class CloudPhoneInfo {
  const CloudPhoneInfo({
    required this.deviceId,
    required this.name,
    required this.model,
    required this.appVersion,
    required this.lastSeenMs,
    required this.readingsWaiting,
  });

  final String deviceId;
  final String name;
  final String model;
  final String appVersion;
  final int lastSeenMs;
  final int readingsWaiting;
}

class CloudLogEntry {
  const CloudLogEntry({
    required this.createdAtMs,
    required this.level,
    required this.category,
    required this.message,
    this.detail,
  });

  final int createdAtMs;
  final String level;
  final String category;
  final String message;
  final String? detail;
}
