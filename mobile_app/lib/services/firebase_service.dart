import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../core/constants/firebase_options_stub.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/water_level_math.dart';
import '../models/reading.dart';
import '../models/station.dart';

class FirebaseService {
  FirebaseService({
    FirebaseAuth? auth,
    FirebaseDatabase? database,
  }) {
    _auth = auth;
    _database = database;
  }

  FirebaseAuth? _auth;
  FirebaseDatabase? _database;
  bool _initialized = false;

  bool get isConfigured => DefaultFirebaseOptions.isConfigured;
  bool get isInitialized => _initialized;

  Future<bool> initialize() async {
    if (!isConfigured) {
      _initialized = false;
      return false;
    }
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
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
        await _auth!.signInAnonymously();
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
      final snap = await _database!.ref('.info/connected').get();
      return snap.value == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> upsertStation(Station station) async {
    await ensureSignedIn();
    await _database!.ref('water/stations/${station.id}').update({
      'name': station.name,
      if (station.calibActualMm != null) 'calib_actual_mm': station.calibActualMm,
      if (station.calibRawLevelMm != null)
        'calib_raw_level_mm': station.calibRawLevelMm,
      if (station.calibDistanceMm != null)
        'calib_distance_mm': station.calibDistanceMm,
      'last_updated': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }

  /// Station metadata from cloud (calibration snapshot).
  Future<
      ({
        String? name,
        int? calibActualMm,
        int? calibRawLevelMm,
        int? calibDistanceMm,
      })?> fetchStationMeta(
    String stationId,
  ) async {
    await ensureSignedIn();
    final snap = await _database!.ref('water/stations/$stationId').get();
    if (!snap.exists || snap.value is! Map) return null;
    final map = Map<Object?, Object?>.from(snap.value as Map);
    return (
      name: map['name'] as String?,
      calibActualMm: (map['calib_actual_mm'] as num?)?.toInt(),
      calibRawLevelMm: (map['calib_raw_level_mm'] as num?)?.toInt(),
      calibDistanceMm: (map['calib_distance_mm'] as num?)?.toInt(),
    );
  }

  /// Historical readings previously uploaded by this (or another) phone.
  /// Returns the full station node (newest first). No client-side truncate.
  Future<List<Reading>> fetchReadings({
    required String stationId,
  }) async {
    await ensureSignedIn();
    final snap = await _database!.ref('water/readings/$stationId').get();
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
      out.add(reading);
    }
    out.sort((a, b) => b.measurementTime.compareTo(a.measurementTime));
    return out;
  }

  /// Best-effort mirror of a phone audit line into RTDB.
  Future<void> uploadAuditLog({
    required String stationId,
    required String level,
    required String category,
    required String message,
    String? detail,
    required int createdAtMs,
  }) async {
    await ensureSignedIn();
    final ref = _database!.ref('water/audit/$stationId').push();
    await ref.set({
      'created_at': createdAtMs,
      'level': level,
      'category': category,
      'message': message,
      if (detail != null && detail.isNotEmpty) 'detail': detail,
    });
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
      updates['water/readings/${station.id}/${reading.firebaseKey}'] =
          reading.toFirebaseMap(
        uploadedAt: uploadedAt,
        calibActualMm: station.calibActualMm,
        calibRawLevelMm: station.calibRawLevelMm,
        calibDistanceMm: station.calibDistanceMm,
      );
    }

    final latestSnap =
        await _database!.ref('water/latest/${station.id}').get();
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
      shouldUpdateLatest = compareReadingRecency(
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
      if (station.calibActualMm != null) 'calib_actual_mm': station.calibActualMm,
      if (station.calibRawLevelMm != null)
        'calib_raw_level_mm': station.calibRawLevelMm,
      if (station.calibDistanceMm != null)
        'calib_distance_mm': station.calibDistanceMm,
      'last_updated': uploadedAt,
    };
    await _database!.ref().update(updates);
  }
}
