import '../core/constants/app_constants.dart';
import '../database/app_database.dart';
import '../models/station.dart';

class StationRepository {
  StationRepository(this._db);

  final AppDatabase _db;

  Future<Station> getDefaultStation() => _db.ensureDefaultStation();

  /// Save gauge calibration: actual water level + sensor snapshot.
  Future<void> updateCalibration({
    required int actualMm,
    int? rawLevelMm,
    int? distanceMm,
  }) async {
    final existing = await _db.getStation(AppConstants.defaultStationId);
    if (existing == null) {
      throw StateError('Default station missing from database');
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.upsertStation(
      Station(
        id: existing.id,
        name: existing.name,
        gatewayIp: existing.gatewayIp,
        wifiSsid: existing.wifiSsid,
        calibActualMm: actualMm,
        calibRawLevelMm: rawLevelMm,
        calibDistanceMm: distanceMm,
        mountHeightMm: null,
        createdAt: existing.createdAt,
        updatedAt: now,
      ),
    );
  }

  Future<void> clearCalibration() async {
    final existing = await _db.getStation(AppConstants.defaultStationId);
    if (existing == null) {
      throw StateError('Default station missing from database');
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.upsertStation(
      Station(
        id: existing.id,
        name: existing.name,
        gatewayIp: existing.gatewayIp,
        wifiSsid: existing.wifiSsid,
        createdAt: existing.createdAt,
        updatedAt: now,
      ),
    );
  }
}
