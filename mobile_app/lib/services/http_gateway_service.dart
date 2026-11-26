import 'package:dio/dio.dart';

import '../core/constants/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../models/gateway_models.dart';
import 'gateway_client.dart';
import 'network_service.dart';

class HttpGatewayService implements GatewayClient {
  HttpGatewayService({
    Dio? dio,
    NetworkService? networkService,
    this.baseUrl = AppConstants.gatewayBaseUrl,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: baseUrl,
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 12),
               sendTimeout: const Duration(seconds: 8),
               headers: {'Accept': 'application/json'},
               validateStatus: (code) => code != null && code < 500,
             ),
           ),
       _network = networkService ?? NetworkService();

  final Dio _dio;
  final NetworkService _network;
  final String baseUrl;

  @override
  bool get isMock => false;

  Future<T> _withGatewayNetwork<T>(Future<T> Function() action) async {
    final onAp = await _network.isConnectedToGatewayWifi();
    final bound = await _network.bindToGatewayNetwork();
    if (!onAp && !bound) {
      throw GatewayException(
        'Not connected to ${AppConstants.gatewaySsid} WiFi. '
        'Connect to the ESP8266 access point first.',
      );
    }
    try {
      return await action();
    } on DioException catch (e) {
      throw GatewayException(_friendlyDio(e), cause: e);
    }
  }

  String _friendlyDio(DioException e) {
    final code = e.response?.statusCode;
    final body = e.response?.data;
    final bodyHint = body == null ? '' : ' Body: $body';
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Gateway timed out at $baseUrl. Stay on ${AppConstants.gatewaySsid} WiFi.';
      case DioExceptionType.connectionError:
        return 'Cannot reach gateway $baseUrl.';
      case DioExceptionType.badResponse:
        return 'Gateway HTTP $code.$bodyHint';
      default:
        if (code != null) return 'Gateway HTTP $code.$bodyHint';
        return 'Gateway request failed: ${e.message ?? e.type.name}';
    }
  }

  void _ensureOk(Response<dynamic> res, String path) {
    final code = res.statusCode ?? 0;
    if (code >= 200 && code < 300) return;
    throw GatewayException(
      'Gateway $path returned HTTP $code. Body: ${res.data}',
    );
  }

  List<GatewayReadingDto> _parseReadings(dynamic data) {
    final maps = extractReadingMaps(data);
    final out = <GatewayReadingDto>[];
    for (final m in maps) {
      try {
        out.add(GatewayReadingDto.fromJson(m));
      } catch (_) {}
    }
    return out;
  }

  @override
  Future<GatewayStatus> getStatus() {
    return _withGatewayNetwork(() async {
      final res = await _dio.get<dynamic>('/status');
      _ensureOk(res, '/status');
      final data = res.data;
      if (data is Map) {
        return GatewayStatus.fromJson(Map<String, dynamic>.from(data));
      }
      return const GatewayStatus(
        device: 'WaterLevel',
        status: 'unknown',
        queueCount: 0,
        lastSequence: 0,
      );
    });
  }

  @override
  Future<List<GatewayReadingDto>> getData({int sinceId = 0, int limit = 200}) {
    return _withGatewayNetwork(() async {
      final all = <GatewayReadingDto>[];
      var since = sinceId;
      // Cap pages so a runaway `more=true` cannot loop forever.
      for (var page = 0; page < 50; page++) {
        final res = await _dio.get<dynamic>(
          '/data',
          queryParameters: {'since': since, 'limit': limit},
        );
        _ensureOk(res, '/data');
        final body = res.data;
        final records = _parseReadings(body);
        all.addAll(records);

        var lastId = since;
        var more = false;
        if (body is Map) {
          final map = Map<String, dynamic>.from(body);
          lastId =
              _asInt(map['last_id'] ?? map['lastId']) ??
              records
                  .map((r) => r.recordId ?? 0)
                  .fold<int>(since, (a, b) => a > b ? a : b);
          more =
              map['more'] == true || map['more'] == 1 || map['more'] == 'true';
        } else if (records.isNotEmpty) {
          lastId = records
              .map((r) => r.recordId ?? 0)
              .fold<int>(since, (a, b) => a > b ? a : b);
          more = records.length >= limit;
        }

        if (!more || records.isEmpty || lastId <= since) break;
        since = lastId;
      }
      return all;
    });
  }

  @override
  Future<AckResponse> ackUpTo(int uptoId) {
    return _withGatewayNetwork(() async {
      final res = await _dio.get<dynamic>(
        '/ack',
        queryParameters: {'upto': uptoId},
      );
      _ensureOk(res, '/ack');
      if (res.data is Map) {
        return AckResponse.fromJson(Map<String, dynamic>.from(res.data as Map));
      }
      return AckResponse(acked: uptoId > 0 ? 1 : 0, status: 'ok');
    });
  }

  @override
  Future<AckResponse> ack(AckRequest request) {
    if (request.uptoId != null) {
      return ackUpTo(request.uptoId!);
    }
    // Fallback for older firmwares that expect POST JSON.
    return _withGatewayNetwork(() async {
      final payloads = <Object>[
        request.toJson(),
        {
          'records': request.records
              .map((r) => {'boot_id': r.bootId, 'seq': r.seq})
              .toList(),
        },
      ];
      Object? lastBody;
      int? lastCode;
      for (final body in payloads) {
        final res = await _dio.post<dynamic>('/ack', data: body);
        lastCode = res.statusCode;
        lastBody = res.data;
        if (res.statusCode != null &&
            res.statusCode! >= 200 &&
            res.statusCode! < 300) {
          if (res.data is Map) {
            return AckResponse.fromJson(
              Map<String, dynamic>.from(res.data as Map),
            );
          }
          return const AckResponse(acked: 0, status: 'ok');
        }
      }
      throw GatewayException(
        'Gateway /ack failed (HTTP $lastCode). Body: $lastBody',
      );
    });
  }

  @override
  Future<void> syncTime(int unixTimestamp) {
    return _withGatewayNetwork(() async {
      // Sensor team contract: GET /time?epoch=<unix seconds>
      final getRes = await _dio.get<dynamic>(
        '/time',
        queryParameters: {'epoch': unixTimestamp},
      );
      if (getRes.statusCode != null &&
          getRes.statusCode! >= 200 &&
          getRes.statusCode! < 300) {
        return;
      }
      // Legacy POST bodies for older firmware.
      final attempts = <Object>[
        {'epoch': unixTimestamp},
        {'unix_timestamp': unixTimestamp},
        {'timestamp': unixTimestamp},
      ];
      for (final body in attempts) {
        final res = await _dio.post<dynamic>('/time', data: body);
        if (res.statusCode != null &&
            res.statusCode! >= 200 &&
            res.statusCode! < 300) {
          return;
        }
      }
      throw GatewayException('Gateway /time not accepted');
    });
  }

  @override
  Future<void> setSendInterval(int seconds) {
    final clamped = seconds.clamp(10, 3600);
    return _withGatewayNetwork(() async {
      final res = await _dio.get<dynamic>(
        '/config',
        queryParameters: {'interval': clamped},
      );
      _ensureOk(res, '/config');
    });
  }
}

int? _asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}
