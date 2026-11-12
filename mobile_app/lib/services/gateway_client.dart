import '../models/gateway_models.dart';

abstract class GatewayClient {
  Future<GatewayStatus> getStatus();

  /// Node B: GET /data?since=&lt;id&gt;&limit=200 — pages while more=true.
  Future<List<GatewayReadingDto>> getData({int sinceId = 0, int limit = 200});

  /// Node B: GET /ack?upto=&lt;id&gt; after local save.
  Future<AckResponse> ackUpTo(int uptoId);

  /// Legacy ACK shape kept for mock / older firmwares.
  Future<AckResponse> ack(AckRequest request);

  /// Node B: GET /time?epoch=&lt;unix seconds&gt;
  Future<void> syncTime(int unixTimestamp);

  /// Node B: GET /config?interval=&lt;10..3600&gt;
  Future<void> setSendInterval(int seconds);

  bool get isMock;
}
