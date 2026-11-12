import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _mountController = TextEditingController();
  bool _loaded = false;

  @override
  void dispose() {
    _mountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stationAsync = ref.watch(stationProvider);
    final useMock = ref.watch(useMockGatewayProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: stationAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (station) {
          if (!_loaded) {
            _mountController.text = station.mountHeightMm?.toString() ?? '';
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
                      const Text('Station', style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text('${station.name} (${station.id})'),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _mountController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Mounting height (mm)',
                          helperText: 'Required to calculate water level from distance',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () async {
                          final text = _mountController.text.trim();
                          final value = text.isEmpty ? null : int.tryParse(text);
                          if (text.isNotEmpty && value == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Enter a valid integer mm value')),
                            );
                            return;
                          }
                          await ref
                              .read(stationRepositoryProvider)
                              .updateMountHeight(value);
                          ref.invalidate(stationProvider);
                          ref.invalidate(dashboardDataProvider);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Mount height saved')),
                            );
                          }
                        },
                        child: const Text('Save mount height'),
                      ),
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
