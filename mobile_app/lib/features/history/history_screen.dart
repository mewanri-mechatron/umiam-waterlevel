import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/utils/water_level_math.dart';
import '../../models/reading.dart';
import '../../widgets/level_chart.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(historyFilterProvider);
    final async = ref.watch(historyReadingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            onPressed: () async {
              final readings = await ref.read(historyReadingsProvider.future);
              if (!context.mounted) return;
              final csv = _toCsv(readings);
              await showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('CSV export'),
                  content: SingleChildScrollView(child: SelectableText(csv)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              );
            },
            icon: const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              children: [
                for (final entry in {
                  HistoryFilter.last24h: '24h',
                  HistoryFilter.last7d: '7d',
                  HistoryFilter.last30d: '30d',
                  HistoryFilter.all: 'All',
                  HistoryFilter.custom: 'Custom',
                }.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(entry.value),
                      selected: filter == entry.key,
                      onSelected: (_) async {
                        ref.read(historyFilterProvider.notifier).state =
                            entry.key;
                        if (entry.key == HistoryFilter.custom) {
                          final range = await showDateRangePicker(
                            context: context,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now().add(const Duration(days: 1)),
                          );
                          if (range != null) {
                            ref.read(customHistoryRangeProvider.notifier).state =
                                HistoryQuery(from: range.start, to: range.end);
                          }
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (readings) {
                final simulated = readings.any((r) => r.isSimulated);
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (simulated)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3CD),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text(
                          'Includes simulated data — not field measurements',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: LevelChart(readings: readings.reversed.toList()),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...readings.map((r) {
                      final ts = DateFormat('yyyy-MM-dd HH:mm:ss').format(
                        DateTime.fromMillisecondsSinceEpoch(
                          r.measurementTime * 1000,
                        ),
                      );
                      return Card(
                        child: ListTile(
                          title: Text(formatLevelMeters(r.waterLevelMm)),
                          subtitle: Text(
                            '$ts\nDistance: ${r.distanceMm ?? '—'} mm · ${sensorStatusLabel(r.status)} · ${r.bootId}/${r.seq}',
                          ),
                          isThreeLine: true,
                        ),
                      );
                    }),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _toCsv(List<Reading> readings) {
    final buf = StringBuffer(
      'measurement_time,distance_mm,water_level_mm,status,boot_id,seq,received_time\n',
    );
    for (final r in readings) {
      buf.writeln(
        '${r.measurementTime},${r.distanceMm},${r.waterLevelMm},${r.status},${r.bootId},${r.seq},${r.receivedTime}',
      );
    }
    return buf.toString();
  }
}
