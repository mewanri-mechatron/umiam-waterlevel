import '../database/app_database.dart';
import '../models/reading.dart';

class ReadingRepository {
  ReadingRepository(this._db);

  final AppDatabase _db;

  Future<Reading?> latest(String stationId) => _db.getLatestReading(stationId);

  Future<List<Reading>> history({
    required String stationId,
    int? fromEpoch,
    int? toEpoch,
  }) {
    return _db.getReadings(
      stationId: stationId,
      fromEpoch: fromEpoch,
      toEpoch: toEpoch,
    );
  }

  Future<int> pendingCount(String stationId) => _db.countPending(stationId);
}
