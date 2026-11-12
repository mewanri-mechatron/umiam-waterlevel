import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/constants/app_constants.dart';
import '../../widgets/status_chip.dart';

class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  String _statusText = 'Not checked';
  String? _message;
  int _downloaded = 0;
  int _acked = 0;
  int? _lastDownload;
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (e) {
      setState(() => _message = e.toString());
    } finally {
      setState(() => _busy = false);
      ref.invalidate(dashboardDataProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final useMock = ref.watch(useMockGatewayProvider);
    final network = ref.watch(networkServiceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Connection')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (useMock)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3CD),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'Mock gateway active — simulated ESP8266 responses',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ESP8266 gateway', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 8),
                  Text('SSID: ${AppConstants.gatewaySsid}'),
                  Text('Gateway IP: ${AppConstants.gatewayIp}'),
                  Text('Base URL: ${AppConstants.gatewayBaseUrl}'),
                  const SizedBox(height: 12),
                  FutureBuilder<bool>(
                    future: network.isConnectedToGatewayWifi(),
                    builder: (context, snap) {
                      final on = snap.data ?? false;
                      return StatusChip(
                        label: on ? 'Connected to WaterLevel WiFi' : 'Not on WaterLevel WiFi',
                        ok: on || useMock,
                        warn: !on,
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Text('Gateway check: $_statusText'),
                  if (_lastDownload != null)
                    Text(
                      'Last successful download: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(_lastDownload! * 1000))}',
                    ),
                  Text('Records downloaded: $_downloaded'),
                  Text('Records acknowledged: $_acked'),
                  if (_message != null) ...[
                    const SizedBox(height: 8),
                    Text(_message!, style: const TextStyle(color: Color(0xFF9B1C1C))),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                      final msg = await network.requestGatewayWifiConnection();
                      setState(() => _message = msg);
                    }),
            icon: const Icon(Icons.wifi),
            label: const Text('Connect to WaterLevel WiFi'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                      final gateway = ref.read(gatewayClientProvider);
                      final status = await gateway.getStatus();
                      setState(() {
                        _statusText =
                            '${status.device} · ${status.status} · queue ${status.queueCount}';
                      });
                    }),
            icon: const Icon(Icons.health_and_safety_outlined),
            label: const Text('Check gateway'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                      final gateway = ref.read(gatewayClientProvider);
                      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
                      await gateway.syncTime(now);
                      setState(() => _message = 'Phone time sent to gateway ($now).');
                    }),
            icon: const Icon(Icons.schedule),
            label: const Text('Synchronize time'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                      final sync = ref.read(syncServiceProvider);
                      final result = await sync.downloadFromGateway();
                      setState(() {
                        _downloaded = result.downloaded;
                        _acked = result.acked;
                        _lastDownload =
                            DateTime.now().millisecondsSinceEpoch ~/ 1000;
                        _message =
                            'Inserted ${result.inserted}, duplicates ${result.duplicates}, ACK ${result.acked}';
                        _statusText = 'Download complete';
                      });
                    }),
            icon: const Icon(Icons.download),
            label: const Text('Download readings'),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
          ],
          const SizedBox(height: 16),
          const Text(
            'Android may treat the ESP8266 hotspot as a network without internet. '
            'Stay connected when prompted; gateway HTTP is limited to 192.168.4.1.',
            style: TextStyle(color: Color(0xFF5B6B7C)),
          ),
        ],
      ),
    );
  }
}
