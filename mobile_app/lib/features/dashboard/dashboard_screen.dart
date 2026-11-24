import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/utils/water_level_math.dart';
import '../../widgets/level_chart.dart';
import '../../widgets/status_chip.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dashboardDataProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('WaterLevel'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.read(dashboardDataProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (data) => RefreshIndicator(
          color: AppColors.deepTeal,
          onRefresh: () => ref.read(dashboardDataProvider.notifier).refresh(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              if (data.usingMockGateway || (data.latest?.isSimulated ?? false))
                Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.warnBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFE8D39A)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.science_outlined, color: AppColors.warn, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Simulated data — not field measurements',
                          style: GoogleFonts.manrope(
                            fontWeight: FontWeight.w700,
                            color: AppColors.warn,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              _LevelHero(
                mountConfigured: data.station.hasCalibration,
                waterLevelMm: resolveDisplayLevelMm(
                  referenceActualMm: data.station.calibActualMm,
                  referenceDistanceMm: data.station.calibDistanceMm,
                  currentDistanceMm: data.latest?.distanceMm,
                ),
                distanceMm: data.latest?.distanceMm,
                status: data.latest?.status,
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  StatusChip(
                    label: data.onGatewayWifi
                        ? 'Gateway WiFi'
                        : 'No gateway WiFi',
                    ok: data.onGatewayWifi,
                    warn: !data.onGatewayWifi && data.usingMockGateway,
                  ),
                  StatusChip(
                    label: data.hasInternet ? 'Online' : 'Offline',
                    ok: data.hasInternet,
                    warn: !data.hasInternet,
                  ),
                  StatusChip(
                    label: 'Pending ${data.pendingCount}',
                    ok: data.pendingCount == 0,
                    warn: data.pendingCount > 0,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _InfoPanel(
                rows: [
                  (
                    'Sensor status',
                    data.latest == null
                        ? 'No reading'
                        : sensorStatusLabel(data.latest!.status)
                  ),
                  ('Last measurement', _fmt(data.latest?.measurementTime)),
                  ('Last cloud upload', _fmt(data.syncState.lastUploadTime)),
                  (
                    'Calibration',
                    data.station.hasCalibration
                        ? 'Actual ${(data.station.calibActualMm! / 1000).toStringAsFixed(2)} ft'
                        : 'Not set (use Setup)'
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                'Recent water level',
                style: GoogleFonts.manrope(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 10),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
                  child: LevelChart(
                    readings: data.recent,
                    station: data.station,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(int? epoch) {
    if (epoch == null) return '—';
    return DateFormat('dd MMM, HH:mm:ss')
        .format(DateTime.fromMillisecondsSinceEpoch(epoch * 1000));
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        rows[i].$1,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        rows[i].$2,
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              if (i < rows.length - 1)
                const Divider(height: 1, color: AppColors.line),
            ],
          ],
        ),
      ),
    );
  }
}

class _LevelHero extends StatelessWidget {
  const _LevelHero({
    required this.mountConfigured,
    required this.waterLevelMm,
    required this.distanceMm,
    required this.status,
  });

  final bool mountConfigured;
  final int? waterLevelMm;
  final int? distanceMm;
  final int? status;

  @override
  Widget build(BuildContext context) {
    final feet = waterLevelMm == null || waterLevelMm == 0xFFFF
        ? null
        : waterLevelMm! / 1000.0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0E3F36), Color(0xFF0A5C4B), Color(0xFF12856C)],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepTeal.withValues(alpha: 0.22),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            'CURRENT LEVEL',
            style: GoogleFonts.manrope(
              color: Colors.white70,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: feet ?? 0),
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) {
              return Text(
                feet == null ? '—' : value.toStringAsFixed(2),
                style: GoogleFonts.manrope(
                  fontSize: 64,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  height: 1,
                  letterSpacing: -1.5,
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          Text(
            'feet AMSL',
            style: GoogleFonts.manrope(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Text(
                  feet == null
                      ? '—'
                      : '${feet.toStringAsFixed(2)} ft AMSL',
                  style: GoogleFonts.manrope(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Raw gap: ${formatDistanceMeters(distanceMm)}'
                  '${status == null ? '' : '  ·  ${sensorStatusLabel(status!)}'}',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.manrope(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
