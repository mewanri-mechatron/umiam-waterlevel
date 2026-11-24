import 'dart:math';

import '../core/constants/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/water_level_math.dart';
import '../database/app_database.dart';
import '../models/gateway_models.dart';
import '../models/reading.dart';
import '../models/station.dart';
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

class CloudPullResult {
  const CloudPullResult({
    required this.fetched,
    required this.inserted,
    required this.duplicates,
    this.calibActualMm,
    this.message,
  });

  final int fetched;
  final int inserted;
  final int duplicates;
  final int? calibActualMm;
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

  Future<int> countLocalReadings({
    String stationId = AppConstants.defaultStationId,
  }) =>
      _db.countReadings(stationId);

  /// Drop phone readings before local midnight today.
  Future<int> purgeLocalReadingsBeforeToday({
    String stationId = AppConstants.defaultStationId,
  }) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final beforeEpoch = start.millisecondsSinceEpoch ~/ 1000;
    return _db.deleteReadingsBefore(
      stationId: stationId,
      beforeEpoch: beforeEpoch,
    );
  }

  /// Workflow A: ESP8266 → phone (ACK only after SQLite commit).
  Future<DownloadResult> downloadFromGateway({
    String stationId = AppConstants.defaultStationId,
  }) async {
    final station = await _db.getStation(stationId);
    if (station == null) {
      throw GatewayException('Station $stationId not found');
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Sensor team flow: /time → /data loop → save → /ack?upto=
    String? statusNote;
    try {
      await _gateway.syncTime(now);
    } catch (_) {
      statusNote = 'Gateway /time skipped';
    }
    try {
      final status = await _gateway.getStatus();
      final pendingCfg = status.pendingInterval > 0
          ? ' · interval pending=${status.pendingInterval}s'
          : '';
      statusNote =
          'queue=${status.queueCount} packets=${status.packets}$pendingCfg';
    } catch (_) {
      statusNote = '${statusNote ?? ''} · /status skipped'.trim();
    }

    final dtos = await _gateway.getData(sinceId: 0);
    final receiveTime = DateTime.now();
    final receiveSec = receiveTime.millisecondsSinceEpoch ~/ 1000;
    final readings = <Reading>[];
    var maxRecordId = 0;

    // Node B often collapses `ts` after power loss (no RTC). Rebuild then.
    final measurementTimes = resolveBatchMeasurementTimes(
      hints: [
        for (final dto in dtos)
          GatewayTimeHint(
            recordId: dto.recordId,
            bootId: dto.bootId,
            seq: dto.seq,
            measurementTime: dto.measurementTime,
            ageSeconds: dto.ageSeconds,
            sendIntervalSeconds: dto.sendIntervalSeconds,
          ),
      ],
      receiveEpochSeconds: receiveSec,
    );

    for (var i = 0; i < dtos.length; i++) {
      final dto = dtos[i];
      final id = dto.recordId ?? 0;
      if (id > maxRecordId) maxRecordId = id;

      final distance = dto.distanceMm;
      // Keep Node B `level` as-is in water_level_mm (true sensor raw level).
      // Display uses actual + gap change; raw Node B level kept for reference.
      final sensorRawLevel = dto.waterLevelMm;

      readings.add(
        Reading(
          stationId: stationId,
          bootId: dto.bootId,
          seq: dto.seq,
          measurementTime: measurementTimes[i],
          receivedTime: receiveSec,
          ageSeconds: dto.ageSeconds > 0
              ? dto.ageSeconds
              : (receiveSec - measurementTimes[i]).clamp(0, 86400 * 30),
          distanceMm: distance,
          waterLevelMm: sensorRawLevel,
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
    if (toAck.isNotEmpty || maxRecordId > 0) {
      try {
        if (maxRecordId > 0) {
          final ack = await _gateway.ackUpTo(maxRecordId);
          acked = ack.acked;
        } else {
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
      } catch (_) {
        // Data is already safe in SQLite — ACK failure must not discard the pull.
        statusNote = '$statusNote · ACK failed (data kept on phone)';
      }
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
      message: statusNote,
    );
  }

  /// Restore history from Firebase into local SQLite (e.g. after reinstall).
  /// Inserts are idempotent on (station, boot, seq); already-local rows stay.
  Future<CloudPullResult> pullFromFirebase({
    String stationId = AppConstants.defaultStationId,
  }) async {
    await _network.bindToInternetNetwork();
    final online = await _network.hasInternet();
    if (!online) {
      return const CloudPullResult(
        fetched: 0,
        inserted: 0,
        duplicates: 0,
        message: 'No internet. Cannot get cloud data.',
      );
    }

    final ready = await _firebase.initialize();
    if (!ready) {
      return const CloudPullResult(
        fetched: 0,
        inserted: 0,
        duplicates: 0,
        message: 'Cloud is not set up on this phone.',
      );
    }

    final station = await _db.getStation(stationId);
    if (station == null) {
      throw SyncException('Station $stationId missing');
    }

    int? cloudActual;
    try {
      final meta = await _firebase.fetchStationMeta(stationId);
      cloudActual = meta?.calibActualMm;
      if (cloudActual != null) {
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        await _db.upsertStation(
          Station(
            id: station.id,
            name: meta?.name ?? station.name,
            gatewayIp: station.gatewayIp,
            wifiSsid: station.wifiSsid,
            calibActualMm: cloudActual,
            calibRawLevelMm: meta?.calibRawLevelMm,
            calibDistanceMm: meta?.calibDistanceMm,
            createdAt: station.createdAt,
            updatedAt: now,
          ),
        );
      }
    } catch (_) {
      // Calibration restore is best-effort; readings still matter.
    }

    final remote = await _firebase.fetchReadings(stationId: stationId);
    final result = await _db.insertReadings(remote);
    final pending = await _db.countPending(stationId);
    final sync = await _db.getSyncState(stationId);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.updateSyncState(
      sync.copyWith(
        lastDownloadTime: now,
        pendingUploadCount: pending,
      ),
    );

    return CloudPullResult(
      fetched: remote.length,
      inserted: result.inserted.length,
      duplicates: result.duplicates.length,
      calibActualMm: cloudActual,
      message: [
        if (cloudActual != null) 'Got shared water-level setting',
        if (result.inserted.isNotEmpty)
          'Got ${result.inserted.length} new readings'
        else if (remote.isEmpty)
          'No cloud readings yet'
        else
          'Readings already on phone',
      ].join(' · '),
    );
  }

  /// Push station calibration so other phones can use the same actual level.
  Future<void> pushCalibrationToCloud({
    String stationId = AppConstants.defaultStationId,
  }) async {
    await _network.bindToInternetNetwork();
    if (!await _network.hasInternet()) return;
    final ready = await _firebase.initialize();
    if (!ready) return;
    final station = await _db.getStation(stationId);
    if (station == null) return;
    await _firebase.upsertStation(station);
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
      // While SoftAP is default route, force cellular/validated WiFi.
      await _network.bindToInternetNetwork();
      final online = await _network.hasInternet();
      if (!online) {
        // One more try: SiteSync may have bound LTE; probe Firebase path by
        // continuing only when connectivity_plus sees a transport.
        final pending = await _db.countPending(stationId);
        return UploadResult(
          uploaded: 0,
          failed: 0,
          pendingRemaining: pending > 0 ? -1 : pending,
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
      Object? lastError;

      // Drain all pending. Firebase multi-path updates stay reliable in
      // ~100-row chunks (payload size / timeout); keep looping until empty.
      for (var round = 0; round < 200; round++) {
        final batch =
            await _db.getPendingUploads(stationId: stationId, limit: 100);
        if (batch.isEmpty) break;

        var roundOk = false;
        for (var attempt = 0; attempt < maxAttempts; attempt++) {
          try {
            await _firebase.uploadReadings(station: station, readings: batch);
            await _db.markUploaded(batch);
            uploaded += batch.length;
            lastError = null;
            failed = 0;
            roundOk = true;
            break;
          } catch (e) {
            lastError = e;
            failed = batch.length;
            final delayMs = min(8000, 400 * pow(2, attempt).toInt());
            await Future<void>.delayed(Duration(milliseconds: delayMs));
          }
        }
        if (!roundOk) break;
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

      if (uploaded == 0 && pending == 0) {
        return UploadResult(
          uploaded: 0,
          failed: 0,
          pendingRemaining: 0,
          message: 'Nothing pending for upload.',
        );
      }

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
