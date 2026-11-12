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
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 12),
                sendTimeout: const Duration(seconds: 8),
                headers: {'Accept': 'application/json'},
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
    if (!onAp) {
      throw GatewayException(
        'Not connected to ${AppConstants.gatewaySsid} WiFi. '
        'Connect to the ESP8266 access point first. '
        'Android may require you to confirm joining a network without internet.',
      );
    }
    await _network.bindToGatewayNetwork();
    try {
      return await action();
    } on DioException catch (e) {
      throw GatewayException(_friendlyDio(e), cause: e);
    } finally {
      // Keep binding while field staff may continue downloads in-session.
    }
  }

  String _friendlyDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Gateway timed out at $baseUrl. Stay on ${AppConstants.gatewaySsid} WiFi.';
      case DioExceptionType.connectionError:
        return 'Cannot reach gateway $baseUrl. Confirm WiFi is ${AppConstants.gatewaySsid} and IP ${AppConstants.gatewayIp}.';
      default:
        return 'Gateway request failed: ${e.message ?? e.type.name}';
    }
  }

  @override
  Future<GatewayStatus> getStatus() {
    return _withGatewayNetwork(() async {
      final res = await _dio.get<Map<String, dynamic>>('/status');
      return GatewayStatus.fromJson(res.data ?? {});
    });
  }

  @override
  Future<List<GatewayReadingDto>> getData({int? sinceSeq, String? cursor}) {
    return _withGatewayNetwork(() async {
      final query = <String, dynamic>{};
      if (cursor != null) {
        query['cursor'] = cursor;
      } else if (sinceSeq != null) {
        query['since'] = sinceSeq;
      } else {
        query['since'] = 0;
      }
      final res = await _dio.get<Map<String, dynamic>>(
        '/data',
        queryParameters: query,
      );
      final list = (res.data?['readings'] as List<dynamic>? ?? []);
      return list
          .map((e) => GatewayReadingDto.fromJson(e as Map<String, dynamic>))
          .toList();
    });
  }

  @override
  Future<AckResponse> ack(AckRequest request) {
    return _withGatewayNetwork(() async {
      final res = await _dio.post<Map<String, dynamic>>(
        '/ack',
        data: request.toJson(),
      );
      return AckResponse.fromJson(res.data ?? {});
    });
  }

  @override
  Future<void> syncTime(int unixTimestamp) {
    return _withGatewayNetwork(() async {
      await _dio.post<Map<String, dynamic>>(
        '/time',
        data: {'unix_timestamp': unixTimestamp},
      );
    });
  }
}
