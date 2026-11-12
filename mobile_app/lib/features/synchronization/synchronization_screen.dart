import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../widgets/status_chip.dart';

class SynchronizationScreen extends ConsumerStatefulWidget {
  const SynchronizationScreen({super.key});

  @override
  ConsumerState<SynchronizationScreen> createState() =>
      _SynchronizationScreenState();
}

class _SynchronizationScreenState extends ConsumerState<SynchronizationScreen> {
  bool _busy = false;
  String? _message;

  String _fmt(int? epoch) {
    if (epoch == null) return 'Never';
    return DateFormat('yyyy-MM-dd HH:mm:ss')
        .format(DateTime.fromMillisecondsSinceEpoch(epoch * 1000));
  }

  @override
  Widget build(BuildContext context) {
    final dash = ref.watch(dashboardDataProvider);
    final firebase = ref.watch(firebaseServiceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Synchronization')),
      body: dash.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (data) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Cloud upload status',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        StatusChip(
                          label: data.hasInternet
                              ? 'Internet available'
                              : 'No internet — uploads wait on the phone',
                          ok: data.hasInternet,
                          warn: !data.hasInternet,
                        ),
                        StatusChip(
                          label: firebase.isConfigured
                              ? 'Firebase configured'
                              : 'Firebase config missing',
                          ok: firebase.isConfigured,
                          warn: !firebase.isConfigured,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _row('Pending upload count', '${data.pendingCount}'),
                    _row('Successfully uploaded', '${data.syncState.uploadedCount}'),
                    _row('Failed uploads', '${data.syncState.failedUploadCount}'),
                    _row('Last successful upload', _fmt(data.syncState.lastUploadTime)),
                    _row('Last gateway contact', _fmt(data.syncState.lastGatewayContact)),
                    if (_message != null) ...[
                      const SizedBox(height: 12),
                      Text(_message!),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() {
                        _busy = true;
                        _message = null;
                      });
                      try {
                        final result = await ref
                            .read(syncServiceProvider)
                            .uploadPendingToFirebase();
                        setState(() {
                          _message = result.message ??
                              'Uploaded ${result.uploaded}. Pending ${result.pendingRemaining}.';
                        });
                        ref.invalidate(dashboardDataProvider);
                      } catch (e) {
                        setState(() => _message = e.toString());
                      } finally {
                        setState(() => _busy = false);
                      }
                    },
              icon: const Icon(Icons.cloud_upload),
              label: const Text('Synchronize now'),
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator()),
            ],
            const SizedBox(height: 16),
            const Text(
              'Records stay on this phone until Firebase accepts them. '
              'Historical readings are never deleted after upload. '
              'Background sync may be delayed by Android power restrictions.',
              style: TextStyle(color: Color(0xFF5B6B7C)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(k)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
