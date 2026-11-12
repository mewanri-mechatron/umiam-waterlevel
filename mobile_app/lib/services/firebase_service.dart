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
      if (station.mountHeightMm != null) 'mount_height_mm': station.mountHeightMm,
      'last_updated': DateTime.now().millisecondsSinceEpoch ~/ 1000,
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
          reading.toFirebaseMap(uploadedAt: uploadedAt);
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
        ...newest.toFirebaseMap(uploadedAt: uploadedAt),
      };
    }

    // Full station node required: rules validate `name` on every write.
    // Writing only `last_updated` fails when the station does not exist yet,
    // and that aborts the entire multi-path update (readings never land).
    updates['water/stations/${station.id}'] = {
      'name': station.name,
      if (station.mountHeightMm != null) 'mount_height_mm': station.mountHeightMm,
      'last_updated': uploadedAt,
    };
    await _database!.ref().update(updates);
  }
}
