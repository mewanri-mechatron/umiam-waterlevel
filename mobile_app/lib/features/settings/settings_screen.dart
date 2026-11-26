import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _intervalController = TextEditingController(text: '30');
  bool _loaded = false;
  bool _savingInterval = false;
  String? _intervalNote;

  static const _presets = <(String, int)>[
    ('30s', 30),
    ('1m', 60),
    ('5m', 300),
    ('15m', 900),
  ];

  @override
  void dispose() {
    _intervalController.dispose();
    super.dispose();
  }

  Future<void> _applyInterval(int seconds) async {
    setState(() {
      _savingInterval = true;
      _intervalNote = null;
    });
    try {
      await ref.read(gatewayClientProvider).setSendInterval(seconds);
      if (!mounted) return;
      setState(() {
        _intervalController.text = '$seconds';
        _intervalNote =
            'Sent to Node B. Shows as pending until Node A’s next send.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _intervalNote =
            'Could not set interval. Join WaterLevel WiFi first.\n$e';
      });
    } finally {
      if (mounted) setState(() => _savingInterval = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stationAsync = ref.watch(stationProvider);
    final useMock = ref.watch(useMockGatewayProvider);
    final dash = ref.watch(dashboardDataProvider);
    final latestInterval = dash.valueOrNull?.latest?.sendIntervalSeconds;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: stationAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (station) {
          if (!_loaded) {
            if (latestInterval != null) {
              _intervalController.text = '$latestInterval';
            }
            _loaded = true;
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Station',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text('${station.name} (${station.id})'),
                      const SizedBox(height: 8),
                      Text(
                        station.hasCalibration
                            ? 'Calibration set (use Setup tab to change)'
                            : 'No calibration yet — set actual water level on Setup',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Node A send interval',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        latestInterval == null
                            ? 'Join WaterLevel WiFi, then set interval (10–3600 s).'
                            : 'Latest reported interval: ${latestInterval}s',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final p in _presets)
                            OutlinedButton(
                              onPressed: _savingInterval
                                  ? null
                                  : () => _applyInterval(p.$2),
                              child: Text(p.$1),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _intervalController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Custom (seconds)',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _savingInterval
                                ? null
                                : () {
                                    final v = int.tryParse(
                                      _intervalController.text.trim(),
                                    );
                                    if (v == null || v < 10 || v > 3600) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Enter 10–3600 seconds',
                                          ),
                                        ),
                                      );
                                      return;
                                    }
                                    _applyInterval(v);
                                  },
                            child: _savingInterval
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Apply'),
                          ),
                        ],
                      ),
                      if (_intervalNote != null) ...[
                        const SizedBox(height: 10),
                        Text(_intervalNote!),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('Use mock gateway'),
                subtitle: const Text(
                  'Simulated ESP8266 for development. Turn off for real hardware at 192.168.4.1',
                ),
                value: useMock,
                onChanged: (v) async {
                  await ref.read(useMockGatewayProvider.notifier).setUseMock(v);
                  ref.invalidate(dashboardDataProvider);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
