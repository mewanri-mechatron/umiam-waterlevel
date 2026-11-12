import 'dart:math';

import '../core/constants/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../models/gateway_models.dart';
import 'gateway_client.dart';

/// Simulated ESP8266 gateway for development without Node B hardware.
class MockGatewayService implements GatewayClient {
  MockGatewayService({Random? random}) : _random = random ?? Random(42);

  final Random _random;
  final List<GatewayReadingDto> _queue = [];
  int _bootId = 10;
  int _seq = 100;
  bool _failNext = false;
  int _downloads = 0;

  @override
  bool get isMock => true;

  void reset() {
    _queue.clear();
    _bootId = 10;
    _seq = 100;
    _failNext = false;
    _downloads = 0;
  }

  void simulateFailureOnce() => _failNext = true;

  void simulateTransmitterRestart() {
    _bootId += 1;
    _seq = 1;
  }

  void enqueueScenarioReadings() {
    _queue.addAll([
      _build(distance: 1200, status: 0),
      _build(distance: 1180, status: 0),
      _build(distance: 1250, status: 0),
      _build(distance: AppConstants.unavailableMm, water: AppConstants.unavailableMm, status: 2, samples: 0),
      _build(distance: 1300, status: 0),
    ]);
    // Duplicate of first identity for re-download testing
    final first = _queue.first;
    _queue.add(GatewayReadingDto(
      version: first.version,
      bootId: first.bootId,
      seq: first.seq,
      ageSeconds: first.ageSeconds,
      distanceMm: first.distanceMm,
      waterLevelMm: first.waterLevelMm,
      status: first.status,
      validSamples: first.validSamples,
      sendIntervalSeconds: first.sendIntervalSeconds,
    ));
  }

  GatewayReadingDto _build({
    required int distance,
    int? water,
    required int status,
    int samples = 5,
  }) {
    final dto = GatewayReadingDto(
      version: AppConstants.payloadVersion,
      bootId: _bootId,
      seq: _seq,
      ageSeconds: 5 + _random.nextInt(25),
      distanceMm: distance,
      waterLevelMm: water ?? (5000 - (distance == AppConstants.unavailableMm ? 0 : distance)),
      status: status,
      validSamples: samples,
      sendIntervalSeconds: 30,
    );
    _seq = (_seq + 1) & 0xFFFF;
    if (_seq == 0) _seq = 1;
    return dto;
  }

  void _ensureQueue() {
    if (_queue.isEmpty) {
      if (_downloads > 0 && _downloads % 3 == 0) {
        simulateTransmitterRestart();
      }
      enqueueScenarioReadings();
    }
  }

  void _maybeFail() {
    if (_failNext) {
      _failNext = false;
      throw GatewayException('Simulated gateway connection failure');
    }
  }

  @override
  Future<GatewayStatus> getStatus() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    _maybeFail();
    _ensureQueue();
    return GatewayStatus(
      device: 'WaterLevel',
      status: 'online',
      queueCount: _queue.length,
      lastSequence: _queue.isEmpty ? _seq : _queue.last.seq,
      lastBootId: _bootId,
    );
  }

  @override
  Future<List<GatewayReadingDto>> getData({int? sinceSeq, String? cursor}) async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    _maybeFail();
    _ensureQueue();
    _downloads += 1;
    // Return a copy of the queue; ACK removes acknowledged items.
    return List<GatewayReadingDto>.from(_queue);
  }

  @override
  Future<AckResponse> ack(AckRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    _maybeFail();
    var count = 0;
    for (final record in request.records) {
      final before = _queue.length;
      _queue.removeWhere(
        (r) => r.bootId == record.bootId && r.seq == record.seq,
      );
      if (_queue.length < before) count += 1;
    }
    return AckResponse(acked: count, status: 'ok');
  }

  @override
  Future<void> syncTime(int unixTimestamp) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _maybeFail();
  }
}
