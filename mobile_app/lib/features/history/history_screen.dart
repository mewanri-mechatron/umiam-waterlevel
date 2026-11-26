import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/utils/display_units.dart';
import '../../core/utils/water_level_math.dart';
import '../../models/reading.dart';
import '../../models/station.dart';
import '../../widgets/level_chart.dart';
import '../../widgets/meecl_branding.dart';
import '../../widgets/unit_picker.dart';

/// Full reading list — water level + raw level, 12-hour times.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(historyFilterProvider);
    final async = ref.watch(historyReadingsProvider);
    final stationAsync = ref.watch(stationProvider);
    final unit = ref.watch(displayLengthUnitProvider);

    return Scaffold(
      backgroundColor: AppColors.mist,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'History',
                          style: GoogleFonts.poppins(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.4,
                          ),
                        ),
                        Text(
                          'Water level · ${unit.longLabel}',
                          style: GoogleFonts.poppins(
                            color: AppColors.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy CSV',
                    onPressed: () async {
                      final readings = await ref.read(
                        historyReadingsProvider.future,
                      );
                      final station = stationAsync.valueOrNull;
                      final csv = _toCsv(
                        readings,
                        station: station,
                        unit: ref.read(displayLengthUnitProvider),
                      );
                      await Clipboard.setData(ClipboardData(text: csv));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Copied ${readings.length} rows'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.download_outlined),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: () {
                      ref.invalidate(historyReadingsProvider);
                      ref.invalidate(dashboardDataProvider);
                    },
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: UnitPicker(dense: true),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final entry in {
                    HistoryFilter.last24h: '24h',
                    HistoryFilter.last7d: '7d',
                    HistoryFilter.last30d: '30d',
                    HistoryFilter.all: 'All',
                    HistoryFilter.custom: 'Dates',
                  }.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(
                          entry.value,
                          style: GoogleFonts.poppins(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                        selected: filter == entry.key,
                        selectedColor: AppColors.okBg,
                        side: BorderSide(
                          color: filter == entry.key
                              ? AppColors.deepTeal
                              : AppColors.outline,
                        ),
                        onSelected: (_) async {
                          ref.read(historyFilterProvider.notifier).state =
                              entry.key;
                          if (entry.key == HistoryFilter.custom) {
                            final range = await showDateRangePicker(
                              context: context,
                              firstDate: DateTime(2020),
                              lastDate: DateTime.now().add(
                                const Duration(days: 1),
                              ),
                            );
                            if (range != null) {
                              ref
                                  .read(customHistoryRangeProvider.notifier)
                                  .state = HistoryQuery(
                                from: range.start,
                                to: range.end,
                              );
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
                skipLoadingOnReload: true,
                loading: () => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '$e',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.poppins(color: AppColors.danger),
                    ),
                  ),
                ),
                data: (readings) {
                  final station = stationAsync.valueOrNull;
                  final chartRows = [...readings].reversed.toList();
                  final footerIndex = readings.isEmpty
                      ? 2
                      : readings.length + 1;
                  return ListView.builder(
                    padding: const EdgeInsets.only(top: 12),
                    itemCount: footerIndex + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${readings.length} reading'
                                '${readings.length == 1 ? '' : 's'}',
                                style: GoogleFonts.poppins(
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.muted,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  10,
                                  10,
                                  6,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: AppColors.outline),
                                ),
                                child: LevelChart(
                                  readings: chartRows,
                                  station: station,
                                  unit: unit,
                                  height: 150,
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                          ),
                        );
                      }
                      if (index == footerIndex) {
                        return const Padding(
                          padding: EdgeInsets.only(top: 16),
                          child: MeeclSiteFooter(),
                        );
                      }
                      if (readings.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 28,
                          ),
                          child: Text(
                            'No readings here yet.\n'
                            'On Level: Connect to the sensor, or tap Sync.',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.poppins(
                              color: AppColors.muted,
                              height: 1.45,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        );
                      }
                      final r = readings[index - 1];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _ReadingRow(
                          reading: r,
                          station: station,
                          unit: unit,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _toCsv(
    List<Reading> readings, {
    Station? station,
    DisplayLengthUnit unit = DisplayLengthUnit.feet,
  }) {
    final buf = StringBuffer(
      'measurement_time,time_12h,water_level_${unit.label},'
      'raw_level_${unit.label},status,boot_id,seq\n',
    );
    for (final r in readings) {
      final cal = resolveDisplayLevelMm(
        referenceActualMm: station?.calibActualMm,
        referenceDistanceMm: station?.calibDistanceMm,
        currentDistanceMm: r.distanceMm,
      );
      buf.writeln(
        '${r.measurementTime},${formatReadingTime(r.measurementTime)},'
        '${cal == null ? '' : unit.fromElevationStored(cal).toStringAsFixed(unit.fractionDigits)},'
        '${r.distanceMm == null ? '' : unit.fromPhysicalMm(r.distanceMm!).toStringAsFixed(unit.fractionDigits)},'
        '${r.status},${r.bootId},${r.seq}',
      );
    }
    return buf.toString();
  }
}

class _ReadingRow extends StatelessWidget {
  const _ReadingRow({
    required this.reading,
    required this.station,
    required this.unit,
  });

  final Reading reading;
  final Station? station;
  final DisplayLengthUnit unit;

  @override
  Widget build(BuildContext context) {
    final r = reading;
    final ts = formatReadingTime(r.measurementTime, withSeconds: true);
    final cal = resolveDisplayLevelMm(
      referenceActualMm: station?.calibActualMm,
      referenceDistanceMm: station?.calibDistanceMm,
      currentDistanceMm: r.distanceMm,
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ts,
            style: GoogleFonts.poppins(
              color: AppColors.muted,
              fontWeight: FontWeight.w500,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _Metric(
                  label: 'Water level',
                  value: formatLevelMeters(cal, unit: unit),
                ),
              ),
              Expanded(
                child: _Metric(
                  label: 'Raw level',
                  value: formatDistanceMeters(r.distanceMm, unit: unit),
                ),
              ),
              Text(
                sensorStatusLabel(r.status),
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: r.status == 0 ? AppColors.ok : AppColors.warn,
                ),
              ),
            ],
          ),
          if (!r.firebaseUploaded) ...[
            const SizedBox(height: 4),
            Text(
              'On phone · not uploaded yet',
              style: GoogleFonts.poppins(
                fontSize: 11,
                color: AppColors.warn,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.poppins(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AppColors.muted,
          ),
        ),
        Text(
          value,
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ],
    );
  }
}
