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
  int _nextId = 1;
  int _interval = 30;
  int _pendingInterval = 0;
  bool _failNext = false;
  int _downloads = 0;

  @override
  bool get isMock => true;

  void reset() {
    _queue.clear();
    _bootId = 10;
    _seq = 100;
    _nextId = 1;
    _interval = 30;
    _pendingInterval = 0;
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
      _build(distance: 1200, level: 3800, status: 0),
      _build(distance: 1180, level: 3820, status: 0),
      _build(distance: 1250, level: 3750, status: 0),
      _build(distance: null, level: null, status: 2, samples: 0),
      _build(distance: 1300, level: 3700, status: 0),
    ]);
    final first = _queue.first;
    _queue.add(
      GatewayReadingDto(
        recordId: _nextId++,
        version: first.version,
        bootId: first.bootId,
        seq: first.seq,
        ageSeconds: first.ageSeconds,
        measurementTime: first.measurementTime,
        distanceMm: first.distanceMm,
        waterLevelMm: first.waterLevelMm,
        status: first.status,
        validSamples: first.validSamples,
        sendIntervalSeconds: first.sendIntervalSeconds,
      ),
    );
  }

  GatewayReadingDto _build({
    required int? distance,
    int? level,
    required int status,
    int samples = 5,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final dto = GatewayReadingDto(
      recordId: _nextId++,
      version: AppConstants.payloadVersion,
      bootId: _bootId,
      seq: _seq,
      ageSeconds: 5 + _random.nextInt(25),
      measurementTime: now - (5 + _random.nextInt(25)),
      distanceMm: distance,
      waterLevelMm: level ??
          (distance == null ? null : 5000 - distance),
      status: status,
      validSamples: samples,
      sendIntervalSeconds: _interval,
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
    final latest = _queue.isEmpty ? null : _queue.last;
    return GatewayStatus(
      device: 'WaterLevel',
      status: 'online',
      queueCount: _queue.length,
      lastSequence: latest?.seq ?? _seq,
      lastBootId: _bootId,
      timeSet: true,
      pendingInterval: _pendingInterval,
      packets: _downloads * 5,
      latest: latest,
    );
  }

  @override
  Future<List<GatewayReadingDto>> getData({int sinceId = 0, int limit = 200}) async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    _maybeFail();
    _ensureQueue();
    _downloads += 1;
    final filtered = _queue
        .where((r) => (r.recordId ?? 0) > sinceId)
        .take(limit)
        .toList();
    return List<GatewayReadingDto>.from(filtered);
  }

  @override
  Future<AckResponse> ackUpTo(int uptoId) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    _maybeFail();
    final before = _queue.length;
    _queue.removeWhere((r) => (r.recordId ?? 0) <= uptoId);
    return AckResponse(acked: before - _queue.length, status: 'ok');
  }

  @override
  Future<AckResponse> ack(AckRequest request) async {
    if (request.uptoId != null) return ackUpTo(request.uptoId!);
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

  @override
  Future<void> setSendInterval(int seconds) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _maybeFail();
    _interval = seconds.clamp(10, 3600);
    _pendingInterval = _interval;
  }
}
