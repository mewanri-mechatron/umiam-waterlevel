import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/theme.dart';
import '../core/utils/display_units.dart';
import '../core/utils/water_level_math.dart';
import '../models/reading.dart';
import '../models/station.dart';

class LevelChart extends StatelessWidget {
  const LevelChart({
    super.key,
    required this.readings,
    this.station,
    this.unit = DisplayLengthUnit.feet,
    this.height = 200,
  });

  final List<Reading> readings;
  final Station? station;
  final DisplayLengthUnit unit;
  final double height;

  @override
  Widget build(BuildContext context) {
    final points = <({int t, double y})>[];
    for (final r in readings) {
      final stored = resolveDisplayLevelMm(
        referenceActualMm: station?.calibActualMm,
        referenceDistanceMm: station?.calibDistanceMm,
        currentDistanceMm: r.distanceMm,
      );
      if (stored == null) continue;
      points.add((t: r.measurementTime, y: unit.fromElevationStored(stored)));
    }
    points.sort((a, b) => a.t.compareTo(b.t));

    if (points.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'No chart data yet',
            style: GoogleFonts.poppins(color: AppColors.muted),
          ),
        ),
      );
    }

    final spots = <FlSpot>[
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), points[i].y),
    ];
    final ys = points.map((p) => p.y).toList();
    final lo = ys.reduce((a, b) => a < b ? a : b);
    final hi = ys.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo).abs();
    final pad = switch (unit) {
      DisplayLengthUnit.millimetres =>
        (span < 50 ? 100.0 : span * 0.15).clamp(20.0, 5000.0),
      DisplayLengthUnit.centimetres =>
        (span < 5 ? 10.0 : span * 0.15).clamp(2.0, 500.0),
      DisplayLengthUnit.feet =>
        (span < 0.05 ? 0.1 : span * 0.15).clamp(0.05, 5.0),
      DisplayLengthUnit.metres =>
        (span < 0.02 ? 0.05 : span * 0.15).clamp(0.02, 2.0),
    };
    final minY = lo - pad;
    final maxY = hi + pad;
    final digits = unit.fractionDigits;

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(
              color: AppColors.line.withValues(alpha: 0.8),
              strokeWidth: 1,
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: unit == DisplayLengthUnit.millimetres ? 52 : 48,
                getTitlesWidget: (v, _) => Text(
                  v.toStringAsFixed(digits),
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    color: AppColors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            bottomTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: AppColors.deepTeal,
              barWidth: 3,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: AppColors.deepTeal.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
