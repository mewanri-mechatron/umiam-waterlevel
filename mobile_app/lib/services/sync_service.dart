import 'dart:math';

import '../core/constants/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/water_level_math.dart';
import '../database/app_database.dart';
import '../models/gateway_models.dart';
import '../models/reading.dart';
import 'firebase_service.dart';
import 'gateway_client.dart';
import 'network_service.dart';

class DownloadResult {
  const DownloadResult({
    required this.downloaded,
    required this.inserted,
    required this.duplicates,
    required this.acked,
    this.message,
  });

  final int downloaded;
  final int inserted;
  final int duplicates;
  final int acked;
  final String? message;
}

class UploadResult {
  const UploadResult({
    required this.uploaded,
    required this.failed,
    required this.pendingRemaining,
    this.message,
  });

  final int uploaded;
  final int failed;
  final int pendingRemaining;
  final String? message;
}

class SyncService {
  SyncService({
    required AppDatabase database,
    required GatewayClient gateway,
    required FirebaseService firebase,
    required NetworkService network,
  }) {
    _db = database;
    _gateway = gateway;
    _firebase = firebase;
    _network = network;
  }

  late final AppDatabase _db;
  late GatewayClient _gateway;
  late final FirebaseService _firebase;
  late final NetworkService _network;
  bool _uploadInFlight = false;

  void updateGateway(GatewayClient gateway) => _gateway = gateway;

  /// Workflow A: ESP8266 → phone (ACK only after SQLite commit).
  Future<DownloadResult> downloadFromGateway({
    String stationId = AppConstants.defaultStationId,
  }) async {
    final station = await _db.getStation(stationId);
    if (station == null) {
      throw GatewayException('Station $stationId not found');
    }

    final status = await _gateway.getStatus();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _gateway.syncTime(now);

    final dtos = await _gateway.getData(sinceSeq: 0);
    final receiveTime = DateTime.now();
    final readings = <Reading>[];

    for (final dto in dtos) {
      if (dto.version != 0 && dto.version != AppConstants.payloadVersion) {
        continue;
      }
      final measurement = measurementTimeFromAge(
        receiveTime: receiveTime,
        ageSeconds: dto.ageSeconds,
      );
      final distance = dto.distanceMm == AppConstants.unavailableMm
          ? null
          : dto.distanceMm;
      final computed = calculateWaterLevelMm(
        mountHeightMm: station.mountHeightMm,
        distanceMm: distance,
      );
      // Prefer computed local water level when mount height known;
      // otherwise keep gateway value unless unavailable.
      int? water = computed;
      if (water == null &&
          dto.waterLevelMm != AppConstants.unavailableMm &&
          dto.waterLevelMm >= 0) {
        water = station.mountHeightMm == null ? null : dto.waterLevelMm;
      }

      readings.add(
        Reading(
          stationId: stationId,
          bootId: dto.bootId,
          seq: dto.seq,
          measurementTime: measurement.millisecondsSinceEpoch ~/ 1000,
          receivedTime: receiveTime.millisecondsSinceEpoch ~/ 1000,
          ageSeconds: dto.ageSeconds,
          distanceMm: distance ?? dto.distanceMm,
          waterLevelMm: water,
          status: dto.status,
          validSamples: dto.validSamples,
          sendIntervalSeconds: dto.sendIntervalSeconds,
          firebaseUploaded: false,
          createdAt: now,
          isSimulated: _gateway.isMock,
        ),
      );
    }

    final result = await _db.insertReadings(readings);
    final toAck = [...result.inserted, ...result.duplicates];

    var acked = 0;
    if (toAck.isNotEmpty) {
      final ack = await _gateway.ack(
        AckRequest(
          stationId: stationId,
          records: toAck
              .map((r) => (bootId: r.bootId, seq: r.seq))
              .toList(),
        ),
      );
      acked = ack.acked;
    }

    final pending = await _db.countPending(stationId);
    final sync = await _db.getSyncState(stationId);
    await _db.updateSyncState(
      sync.copyWith(
        lastDownloadTime: now,
        lastGatewayContact: now,
        pendingUploadCount: pending,
      ),
    );

    return DownloadResult(
      downloaded: dtos.length,
      inserted: result.inserted.length,
      duplicates: result.duplicates.length,
      acked: acked,
      message: status.isOnline
          ? null
          : 'Gateway reported status "${status.status}"',
    );
  }

  /// Workflow B: phone → Firebase with retry/backoff.
  /// Only rows with `firebase_uploaded = 0` are sent; successful uploads are
  /// marked immediately so later cycles never re-push the same reading.
  Future<UploadResult> uploadPendingToFirebase({
    String stationId = AppConstants.defaultStationId,
    int maxAttempts = 4,
  }) async {
    if (_uploadInFlight) {
      final pending = await _db.countPending(stationId);
      return UploadResult(
        uploaded: 0,
        failed: 0,
        pendingRemaining: pending,
        message: 'Upload already in progress.',
      );
    }
    _uploadInFlight = true;
    try {
      if (!await _network.hasInternet()) {
        return const UploadResult(
          uploaded: 0,
          failed: 0,
          pendingRemaining: -1,
          message: 'No internet connection. Pending records stay on the phone.',
        );
      }

      final ready = await _firebase.initialize();
      if (!ready) {
        final pending = await _db.countPending(stationId);
        return UploadResult(
          uploaded: 0,
          failed: 0,
          pendingRemaining: pending,
          message:
              'Firebase client config is not set. Local records are preserved.',
        );
      }

      final station = await _db.getStation(stationId);
      if (station == null) {
        throw SyncException('Station $stationId missing');
      }

      var uploaded = 0;
      var failed = 0;
      // Re-query pending only — already-pushed rows are excluded by SQLite.
      final batch =
          await _db.getPendingUploads(stationId: stationId, limit: 40);
      if (batch.isEmpty) {
        final pending = await _db.countPending(stationId);
        return UploadResult(
          uploaded: 0,
          failed: 0,
          pendingRemaining: pending,
          message: 'Nothing pending for upload.',
        );
      }

      Object? lastError;
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        try {
          await _firebase.uploadReadings(station: station, readings: batch);
          // Mark before returning so concurrent workers never re-select these.
          await _db.markUploaded(batch);
          uploaded = batch.length;
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          failed = batch.length;
          final delayMs = min(8000, 400 * pow(2, attempt).toInt());
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
      }

      final pending = await _db.countPending(stationId);
      final sync = await _db.getSyncState(stationId);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _db.updateSyncState(
        sync.copyWith(
          lastUploadTime: uploaded > 0 ? now : sync.lastUploadTime,
          pendingUploadCount: pending,
          uploadedCount: sync.uploadedCount + uploaded,
          failedUploadCount: lastError == null
              ? sync.failedUploadCount
              : sync.failedUploadCount + failed,
        ),
      );

      return UploadResult(
        uploaded: uploaded,
        failed: lastError == null ? 0 : failed,
        pendingRemaining: pending,
        message: lastError?.toString(),
      );
    } finally {
      _uploadInFlight = false;
    }
  }
}
