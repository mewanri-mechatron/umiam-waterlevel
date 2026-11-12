import '../core/constants/app_constants.dart';
import '../database/app_database.dart';
import '../models/station.dart';

class StationRepository {
  StationRepository(this._db);

  final AppDatabase _db;

  Future<Station> getDefaultStation() async {
    var station = await _db.getStation(AppConstants.defaultStationId);
    if (station == null) {
      throw StateError('Default station missing from database');
    }
    // Field default so non-technical users see a level without setup.
    if (station.mountHeightMm == null) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final updated = station.copyWith(mountHeightMm: 5000, updatedAt: now);
      await _db.upsertStation(updated);
      return updated;
    }
    return station;
  }

  Future<void> updateMountHeight(int? mountHeightMm) async {
    final existing = await _db.getStation(AppConstants.defaultStationId);
    if (existing == null) {
      throw StateError('Default station missing from database');
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.upsertStation(
      existing.copyWith(
        mountHeightMm: mountHeightMm,
        clearMountHeight: mountHeightMm == null,
        updatedAt: now,
      ),
    );
  }
}
