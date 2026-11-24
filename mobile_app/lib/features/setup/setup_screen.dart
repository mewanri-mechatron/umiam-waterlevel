import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/utils/water_level_math.dart';
import '../../widgets/unit_picker.dart';

/// Set the real gauge reading once — saved to phone + cloud for all phones.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _actualLevel = TextEditingController(text: '3201.90');
  bool _busy = false;
  bool _prefillsDone = false;

  @override
  void dispose() {
    _actualLevel.dispose();
    super.dispose();
  }

  void _prefillFromStation(int? calibActualMm) {
    if (_prefillsDone || calibActualMm == null) return;
    _prefillsDone = true;
    _actualLevel.text = (calibActualMm / 1000.0).toStringAsFixed(2);
  }

  Future<void> _saveCalibration({
    required int? rawLevelMm,
    required int? distanceMm,
  }) async {
    final known = double.tryParse(_actualLevel.text.trim());
    if (known == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the real water level, e.g. 3201.90')),
      );
      return;
    }
    final snap = calibrationSnapshot(
      actualWaterLevelFeet: known,
      rawLevelMm: rawLevelMm,
      distanceMm: distanceMm,
    );
    if (snap.distanceMm == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Need a raw level reading first. On Level, connect to the sensor and sync.',
          ),
        ),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      await ref.read(stationRepositoryProvider).updateCalibration(
            actualMm: snap.actualMm,
            rawLevelMm: snap.rawLevelMm,
            distanceMm: snap.distanceMm,
          );
      try {
        await ref
            .read(syncServiceProvider)
            .pushCalibrationToCloud()
            .timeout(const Duration(seconds: 20));
      } catch (_) {}
      ref.invalidate(stationProvider);
      ref.invalidate(dashboardDataProvider);
      ref.invalidate(historyReadingsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved ${known.toStringAsFixed(2)} ft and shared to cloud.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dash = ref.watch(dashboardDataProvider);
    final unit = ref.watch(displayLengthUnitProvider);
    final data = dash.asData?.value;
    final station = data?.station;
    final latest = data?.latest;
    final distMm = latest?.distanceMm;
    final rawMm = latest?.waterLevelMm;
    final hasGap = distMm != null && distMm != 0xFFFF;

    if (station != null) {
      _prefillFromStation(station.calibActualMm);
    }

    return Scaffold(
      backgroundColor: AppColors.mist,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
          children: [
            Text(
              'Setup',
              style: GoogleFonts.poppins(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.4,
              ),
            ),
            Text(
              'Calibration in feet AMSL · shared to all phones',
              style: GoogleFonts.poppins(
                color: AppColors.muted,
                fontWeight: FontWeight.w500,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Display units',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const UnitPicker(dense: true),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Real water level',
                    style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Level (ft) = your number + change in sensor gap.',
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      color: AppColors.muted,
                      fontWeight: FontWeight.w500,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _InfoRow(
                    label: 'Current raw level',
                    value: formatDistanceMeters(distMm, unit: unit),
                    warn: !hasGap,
                  ),
                  if (station?.hasCalibration == true) ...[
                    const SizedBox(height: 8),
                    _InfoRow(
                      label: 'Saved level',
                      value: formatLevelMeters(
                        station!.calibActualMm,
                        unit: unit,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  TextField(
                    controller: _actualLevel,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Real water level now',
                      hintText: '3201.90',
                      suffixText: 'ft',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: _busy || !hasGap
                        ? null
                        : () => _saveCalibration(
                              rawLevelMm: rawMm,
                              distanceMm: distMm,
                            ),
                    child: Text(_busy ? 'Saving…' : 'Save level'),
                  ),
                  if (!hasGap) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Connect to the sensor on Level first to capture raw gap.',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: AppColors.warn,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'More',
              style: GoogleFonts.poppins(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 8),
            _LinkTile(
              icon: Icons.receipt_long_outlined,
              title: 'Activity log',
              subtitle: 'Sync and error history',
              onTap: () => context.push('/audit'),
            ),
            _LinkTile(
              icon: Icons.timer_outlined,
              title: 'Sensor interval',
              subtitle: 'How often Node B records',
              onTap: () => context.push('/advanced'),
            ),
            if (dash.hasError) ...[
              const SizedBox(height: 12),
              Text(
                'Local data load issue: ${dash.error}',
                style: GoogleFonts.poppins(
                  color: AppColors.danger,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.outline),
      ),
      child: child,
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.warn = false,
  });

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: warn ? AppColors.warnBg : AppColors.panelSoft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: warn ? AppColors.warn : AppColors.muted,
            ),
          ),
          Text(
            value,
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.w600,
              color: warn ? AppColors.warn : AppColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.outline),
            ),
            child: Row(
              children: [
                Icon(icon, color: AppColors.deepTeal),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        subtitle,
                        style: GoogleFonts.poppins(
                          color: AppColors.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
