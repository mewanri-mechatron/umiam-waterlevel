import '../models/gateway_models.dart';

abstract class GatewayClient {
  Future<GatewayStatus> getStatus();
  Future<List<GatewayReadingDto>> getData({int? sinceSeq, String? cursor});
  Future<AckResponse> ack(AckRequest request);
  Future<void> syncTime(int unixTimestamp);
  bool get isMock;
}
