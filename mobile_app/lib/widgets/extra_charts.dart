import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/theme.dart';
import '../core/utils/display_units.dart';
import '../core/utils/water_level_math.dart';
import '../models/reading.dart';
import '../models/station.dart';
import '../services/weather_service.dart';

/// Operating bands in feet AMSL (same as web).
const kZoneSafeMaxFt = 3200.0;
const kZoneWarnMaxFt = 3210.0;
const kZoneCritMaxFt = 3220.0;

class ChartCardShell extends StatelessWidget {
  const ChartCardShell({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.poppins(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        color: AppColors.muted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class ForecastChart extends StatelessWidget {
  const ForecastChart({
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

  static ({List<FlSpot> observed, List<FlSpot> forecast, String note})
      series({
    required List<Reading> readings,
    Station? station,
    required DisplayLengthUnit unit,
  }) {
    final chrono = <({int t, double yFt})>[];
    for (final r in readings) {
      final stored = resolveDisplayLevelMm(
        referenceActualMm: station?.calibActualMm,
        referenceDistanceMm: station?.calibDistanceMm,
        currentDistanceMm: r.distanceMm,
      );
      if (stored == null) continue;
      chrono.add((t: r.measurementTime, yFt: stored / 1000.0));
    }
    chrono.sort((a, b) => a.t.compareTo(b.t));
    if (chrono.length < 2) {
      return (
        observed: const <FlSpot>[],
        forecast: const <FlSpot>[],
        note: 'Need more readings for forecast',
      );
    }

    final observed = [
      for (final p in chrono)
        FlSpot(p.t.toDouble(), unit.fromElevationStored(p.yFt * 1000)),
    ];

    final window = chrono.length > 12 ? chrono.sublist(chrono.length - 12) : chrono;
    final first = window.first;
    final last = window.last;
    final dtH = (last.t - first.t) / 3600.0;
    final dFt = last.yFt - first.yFt;
    final rateFtPerH = dtH > 0.05 ? dFt / dtH : 0.0;
    final lastFt = last.yFt;
    final lastT = last.t;
    const horizonH = 24.0;
    const steps = 8;
    final forecast = <FlSpot>[
      FlSpot(lastT.toDouble(), unit.fromElevationStored(lastFt * 1000)),
    ];
    for (var i = 1; i <= steps; i++) {
      final h = (horizonH * i) / steps;
      final ft = lastFt + rateFtPerH * h;
      forecast.add(
        FlSpot(
          (lastT + (h * 3600).round()).toDouble(),
          unit.fromElevationStored(ft * 1000),
        ),
      );
    }
    final sign = rateFtPerH >= 0 ? '+' : '';
    final rateDisp = unit.fromElevationStored(rateFtPerH * 1000);
    final note =
        'Trend $sign${rateDisp.toStringAsFixed(unit.fractionDigits)} ${unit.label}/h · 24h outlook';
    return (observed: observed, forecast: forecast, note: note);
  }

  @override
  Widget build(BuildContext context) {
    final s = series(readings: readings, station: station, unit: unit);
    if (s.observed.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            s.note,
            style: GoogleFonts.poppins(color: AppColors.muted, fontSize: 12),
          ),
        ),
      );
    }

    final allY = [
      ...s.observed.map((e) => e.y),
      ...s.forecast.map((e) => e.y),
      unit.fromElevationStored(kZoneSafeMaxFt * 1000),
      unit.fromElevationStored(kZoneWarnMaxFt * 1000),
      unit.fromElevationStored(kZoneCritMaxFt * 1000),
    ];
    final lo = allY.reduce((a, b) => a < b ? a : b);
    final hi = allY.reduce((a, b) => a > b ? a : b);
    final pad = (hi - lo).abs() * 0.12 + 0.05;
    final digits = unit.fractionDigits;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            s.note,
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: height,
          child: LineChart(
            LineChartData(
              minY: lo - pad,
              maxY: hi + pad,
              minX: s.observed.first.x,
              maxX: s.forecast.last.x,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: AppColors.line.withValues(alpha: 0.8),
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(show: false),
              extraLinesData: ExtraLinesData(
                horizontalLines: [
                  HorizontalLine(
                    y: unit.fromElevationStored(kZoneSafeMaxFt * 1000),
                    color: AppColors.ok.withValues(alpha: 0.7),
                    strokeWidth: 1,
                    dashArray: [6, 4],
                  ),
                  HorizontalLine(
                    y: unit.fromElevationStored(kZoneWarnMaxFt * 1000),
                    color: AppColors.warn.withValues(alpha: 0.8),
                    strokeWidth: 1,
                    dashArray: [6, 4],
                  ),
                  HorizontalLine(
                    y: unit.fromElevationStored(kZoneCritMaxFt * 1000),
                    color: AppColors.danger.withValues(alpha: 0.75),
                    strokeWidth: 1,
                    dashArray: [6, 4],
                  ),
                ],
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                bottomTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 48,
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
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: s.observed,
                  isCurved: true,
                  color: AppColors.deepTeal,
                  barWidth: 2.5,
                  dotData: const FlDotData(show: false),
                ),
                LineChartBarData(
                  spots: s.forecast,
                  isCurved: true,
                  color: AppColors.warn,
                  barWidth: 2,
                  dashArray: [6, 4],
                  dotData: const FlDotData(show: false),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            _LegendDot(color: AppColors.deepTeal, label: 'Observed'),
            const SizedBox(width: 12),
            _LegendDot(color: AppColors.warn, label: 'Forecast 24h', dashed: true),
          ],
        ),
      ],
    );
  }
}

class RawGapChart extends StatelessWidget {
  const RawGapChart({
    super.key,
    required this.readings,
    this.unit = DisplayLengthUnit.feet,
    this.height = 160,
  });

  final List<Reading> readings;
  final DisplayLengthUnit unit;
  final double height;

  @override
  Widget build(BuildContext context) {
    final points = <({int t, double y})>[];
    for (final r in readings) {
      if (!r.hasValidDistance) continue;
      points.add((
        t: r.measurementTime,
        y: unit.fromPhysicalMm(r.distanceMm!),
      ));
    }
    points.sort((a, b) => a.t.compareTo(b.t));
    if (points.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'No raw gap data yet',
            style: GoogleFonts.poppins(color: AppColors.muted, fontSize: 12),
          ),
        ),
      );
    }

    final spots = [
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), points[i].y),
    ];
    final ys = points.map((p) => p.y).toList();
    final lo = ys.reduce((a, b) => a < b ? a : b);
    final hi = ys.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo).abs();
    final pad = (span < 0.05 ? 0.1 : span * 0.15).clamp(0.05, 5.0);
    final digits = unit.fractionDigits;
    const rawColor = Color(0xFF4C635C);

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minY: lo - pad,
          maxY: hi + pad,
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
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 48,
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
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: rawColor,
              barWidth: 2.2,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: rawColor.withValues(alpha: 0.14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RainBarChart extends StatelessWidget {
  const RainBarChart({
    super.key,
    required this.daily,
    this.height = 160,
    this.loading = false,
    this.error,
  });

  final List<DailyRain> daily;
  final double height;
  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return SizedBox(
        height: height,
        child: const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    if (error != null) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            error!,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(color: AppColors.muted, fontSize: 12),
          ),
        ),
      );
    }
    if (daily.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'No rainfall data',
            style: GoogleFonts.poppins(color: AppColors.muted, fontSize: 12),
          ),
        ),
      );
    }

    final maxMm = daily.map((d) => d.mm).fold<double>(0, (a, b) => a > b ? a : b);
    final maxY = (maxMm < 1 ? 2.0 : maxMm * 1.25);

    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
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
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                getTitlesWidget: (v, _) => Text(
                  v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1),
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    color: AppColors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                getTitlesWidget: (v, meta) {
                  final i = v.round();
                  if (i < 0 || i >= daily.length) {
                    return const SizedBox.shrink();
                  }
                  // Show every other label when many days.
                  if (daily.length > 8 && i % 2 != 0) {
                    return const SizedBox.shrink();
                  }
                  final d = daily[i].day;
                  return Text(
                    '${d.day}/${d.month}',
                    style: GoogleFonts.poppins(
                      fontSize: 9,
                      color: AppColors.muted,
                      fontWeight: FontWeight.w500,
                    ),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < daily.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: daily[i].mm,
                    width: daily.length > 10 ? 8 : 12,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4),
                    ),
                    color: AppColors.teal,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({
    required this.color,
    required this.label,
    this.dashed = false,
  });

  final Color color;
  final String label;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 3,
          decoration: BoxDecoration(
            color: dashed ? Colors.transparent : color,
            border: dashed
                ? Border(
                    bottom: BorderSide(
                      color: color,
                      width: 2,
                      style: BorderStyle.solid,
                    ),
                  )
                : null,
            borderRadius: BorderRadius.circular(2),
          ),
          child: dashed
              ? CustomPaint(painter: _DashPainter(color))
              : null,
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.poppins(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AppColors.muted,
          ),
        ),
      ],
    );
  }
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    const dash = 3.0;
    const gap = 2.0;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, size.height / 2), Offset(x + dash, size.height / 2), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
