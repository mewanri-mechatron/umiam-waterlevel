import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/constants/app_constants.dart';
import '../../core/utils/display_units.dart';
import '../../core/utils/water_level_math.dart';
import '../../models/reading.dart';
import '../../models/station.dart';
import '../../services/auto_sync_controller.dart';
import '../../widgets/level_chart.dart';
import '../../widgets/unit_picker.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  AutoSyncController? _auto;
  VoidCallback? _autoListener;
  bool _wasBusy = false;
  bool _wasOnGateway = false;
  bool _actionBusy = false;
  _ChartRange _chartRange = _ChartRange.h24;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _attachAutoSync());
  }

  void _attachAutoSync() {
    final auto = ref.read(autoSyncControllerProvider);
    if (!identical(_auto, auto)) {
      if (_auto != null && _autoListener != null) {
        _auto!.removeListener(_autoListener!);
      }
      _auto = auto;
      _autoListener = () {
        if (!mounted) return;
        final snap = _auto!.snapshot;
        final busy = snap.busy;
        final connectedNow = snap.onGateway;
        if ((_wasBusy && !busy) ||
            (!_wasOnGateway && connectedNow) ||
            (_wasOnGateway && !connectedNow)) {
          ref.invalidate(dashboardDataProvider);
          ref.invalidate(historyReadingsProvider);
          ref.invalidate(stationProvider);
        }
        _wasBusy = busy;
        _wasOnGateway = connectedNow;
        setState(() {});
      };
      _auto!.addListener(_autoListener!);
    }
    unawaited(_auto!.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _auto?.refreshConnectionStatus();
      unawaited(_auto?.runCycle());
      ref.invalidate(dashboardDataProvider);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_auto != null && _autoListener != null) {
      _auto!.removeListener(_autoListener!);
    }
    super.dispose();
  }

  Future<void> _turnWifiOn() async {
    setState(() => _actionBusy = true);
    await ref.read(networkServiceProvider).ensureWifiEnabled();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _auto?.refreshConnectionStatus();
    if (mounted) setState(() => _actionBusy = false);
  }

  Future<void> _connectSensor() async {
    final network = ref.read(networkServiceProvider);
    final auto = ref.read(autoSyncControllerProvider);
    _auto ??= auto;

    setState(() => _actionBusy = true);
    try {
      if (await network.isOnGatewayFast(allowHttpProbe: false)) {
        await auto.refreshConnectionStatus();
        await auto.runCycle(force: true);
        _refreshData();
        return;
      }

      final msg = await network.requestGatewayWifiConnection();
      await ref.read(auditLogServiceProvider).info(
            'Connect to sensor WiFi',
            category: 'network',
            detail: msg,
          );

      var connected = false;
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (!mounted) return;
        final onGateway =
            await network.isOnGatewayFast(allowHttpProbe: false);
        await auto.refreshConnectionStatus();
        if (onGateway || auto.snapshot.onGateway) {
          connected = true;
          break;
        }
        if (mounted) setState(() {});
      }

      if (connected) {
        await auto.runCycle(force: true);
        _refreshData();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Join “${AppConstants.gatewaySsid}” WiFi, then tap Sync',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  void _refreshData() {
    ref.invalidate(dashboardDataProvider);
    ref.invalidate(historyReadingsProvider);
    ref.invalidate(stationProvider);
  }

  Future<void> _syncNow() async {
    final auto = ref.read(autoSyncControllerProvider);
    final network = ref.read(networkServiceProvider);
    _auto ??= auto;
    if (!auto.snapshot.wifiOn && !auto.snapshot.hasInternet) {
      await _turnWifiOn();
      return;
    }
    await network.isOnGatewayFast(allowHttpProbe: false);
    await auto.refreshConnectionStatus();
    await auto.runCycle(force: true);
    _refreshData();
  }

  @override
  Widget build(BuildContext context) {
    final dash = ref.watch(dashboardDataProvider);
    final auto = ref.watch(autoSyncControllerProvider);
    if (!identical(_auto, auto)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _attachAutoSync());
    }
    final snap = auto.snapshot;
    final unit = ref.watch(displayLengthUnitProvider);

    // Never blank-screen: show chrome while first load finishes.
    final data = dash.asData?.value;
    final station = data?.station;
    final latest = data?.latest;
    final recent = data?.recent ?? const <Reading>[];
    final pending =
        snap.pendingCount > 0 ? snap.pendingCount : (data?.pendingCount ?? 0);
    final busy = snap.busy || _actionBusy;

    final levelMm = latest == null || station == null
        ? null
        : resolveDisplayLevelMm(
            referenceActualMm: station.calibActualMm,
            referenceDistanceMm: station.calibDistanceMm,
            currentDistanceMm: latest.distanceMm,
          );
    final levelLabel = levelMm == null
        ? null
        : unit.formatElevation(levelMm, withUnit: false);

    final chartRows = _filterChart(recent, _chartRange);
    final delta24 = _delta24h(recent, station, unit);
    final rangeStats = _rangeStats(chartRows, station, unit);

    return Scaffold(
      backgroundColor: AppColors.mist,
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.deepTeal,
          onRefresh: () async {
            await _syncNow();
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              _BrandHeader(snap: snap),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(child: UnitPicker(dense: true)),
                ],
              ),
              const SizedBox(height: 14),
              _HeroCard(
                levelLabel: levelLabel,
                unit: unit,
                measured: latest?.measurementTime,
                delta24: delta24,
                trend: rangeStats.trend,
                high: rangeStats.high,
                low: rangeStats.low,
                nextLabel: _nextReadingLabel(latest),
                loading: dash.isLoading && data == null,
              ),
              const SizedBox(height: 12),
              _DiagnosticsCard(
                station: station,
                latest: latest,
                unit: unit,
                pending: pending,
                snap: snap,
              ),
              const SizedBox(height: 12),
              _StatusCard(
                snap: snap,
                pending: pending,
                busy: busy,
              ),
              const SizedBox(height: 12),
              _PrimaryAction(
                snap: snap,
                busy: busy,
                actionBusy: _actionBusy,
                pending: pending,
                onWifi: _turnWifiOn,
                onConnect: _connectSensor,
                onSync: _syncNow,
              ),
              const SizedBox(height: 18),
              _ChartHeader(
                range: _chartRange,
                onChanged: (r) => setState(() => _chartRange = r),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.outline),
                ),
                child: LevelChart(
                  readings: chartRows,
                  station: station,
                  unit: unit,
                  height: 168,
                ),
              ),
              if (dash.hasError) ...[
                const SizedBox(height: 12),
                Text(
                  'Could not load local data: ${dash.error}',
                  style: GoogleFonts.poppins(
                    color: AppColors.danger,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Reading> _filterChart(List<Reading> recent, _ChartRange range) {
    if (recent.isEmpty) return recent;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final from = switch (range) {
      _ChartRange.h24 => now - 24 * 3600,
      _ChartRange.d7 => now - 7 * 24 * 3600,
    };
    final filtered =
        recent.where((r) => r.measurementTime >= from).toList();
    return filtered.isEmpty ? recent : filtered;
  }

  String? _delta24h(
    List<Reading> recent,
    Station? station,
    DisplayLengthUnit unit,
  ) {
    if (station == null || recent.isEmpty) return null;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final cutoff = now - 24 * 3600;
    int? resolve(Reading r) => resolveDisplayLevelMm(
          referenceActualMm: station.calibActualMm,
          referenceDistanceMm: station.calibDistanceMm,
          currentDistanceMm: r.distanceMm,
        );
    final newest = resolve(recent.last);
    Reading? old;
    for (final r in recent) {
      if (r.measurementTime <= cutoff) old = r;
    }
    old ??= recent.first;
    final oldest = resolve(old);
    if (newest == null || oldest == null) return null;
    final d = unit.fromElevationStored(newest) -
        unit.fromElevationStored(oldest);
    final sign = d >= 0 ? '+' : '';
    return '$sign${d.toStringAsFixed(unit.fractionDigits)} ${unit.label}';
  }

  ({String trend, String high, String low}) _rangeStats(
    List<Reading> rows,
    Station? station,
    DisplayLengthUnit unit,
  ) {
    final vals = <double>[];
    for (final r in rows) {
      final stored = resolveDisplayLevelMm(
        referenceActualMm: station?.calibActualMm,
        referenceDistanceMm: station?.calibDistanceMm,
        currentDistanceMm: r.distanceMm,
      );
      if (stored == null) continue;
      vals.add(unit.fromElevationStored(stored));
    }
    if (vals.isEmpty) {
      return (trend: '—', high: '—', low: '—');
    }
    final hi = vals.reduce((a, b) => a > b ? a : b);
    final lo = vals.reduce((a, b) => a < b ? a : b);
    final delta = vals.last - vals.first;
    final trend = delta.abs() < 0.01
        ? 'Steady'
        : (delta > 0 ? 'Rising' : 'Falling');
    return (
      trend: trend,
      high: '${hi.toStringAsFixed(unit.fractionDigits)} ${unit.label}',
      low: '${lo.toStringAsFixed(unit.fractionDigits)} ${unit.label}',
    );
  }

  String _nextReadingLabel(Reading? latest) {
    if (latest == null) return '—';
    final interval = latest.sendIntervalSeconds.clamp(10, 86400);
    final next = latest.measurementTime + interval;
    final dt = DateTime.fromMillisecondsSinceEpoch(next * 1000);
    return DateFormat('h:mm a').format(dt);
  }
}

enum _ChartRange { h24, d7 }

class _BrandHeader extends StatelessWidget {
  const _BrandHeader({required this.snap});
  final AutoSyncSnapshot snap;

  @override
  Widget build(BuildContext context) {
    final live = snap.hasInternet || snap.onGateway;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.deepTeal,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.water_drop, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    'Umiam Dam',
                    style: GoogleFonts.poppins(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.4,
                    ),
                  ),
                  _Badge(
                    label: live ? 'Live' : 'Offline',
                    ok: live,
                  ),
                  if (snap.onGateway)
                    const _Badge(label: 'At sensor', ok: true),
                ],
              ),
              Text(
                'Meghalaya Reservoir · Stage - 1',
                style: GoogleFonts.poppins(
                  color: AppColors.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.ok});
  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ok ? AppColors.okBg : AppColors.warnBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ok ? AppColors.ok : AppColors.warn,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: ok ? AppColors.okInk : AppColors.warn,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.levelLabel,
    required this.unit,
    required this.measured,
    required this.delta24,
    required this.trend,
    required this.high,
    required this.low,
    required this.nextLabel,
    required this.loading,
  });

  final String? levelLabel;
  final DisplayLengthUnit unit;
  final int? measured;
  final String? delta24;
  final String trend;
  final String high;
  final String low;
  final String nextLabel;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final date = measured == null
        ? '—'
        : DateFormat('dd MMM yyyy')
            .format(DateTime.fromMillisecondsSinceEpoch(measured! * 1000));
    final time = measured == null
        ? '—'
        : DateFormat('h:mm a')
            .format(DateTime.fromMillisecondsSinceEpoch(measured! * 1000));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Current water level',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.muted,
                  letterSpacing: 0.2,
                ),
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    date,
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppColors.muted,
                    ),
                  ),
                  Text(
                    time,
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (loading && levelLabel == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  levelLabel ?? '—',
                  style: GoogleFonts.poppins(
                    fontSize: 48,
                    fontWeight: FontWeight.w600,
                    height: 1,
                    letterSpacing: -1.2,
                    color: AppColors.deepTeal,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 8),
                  child: Text(
                    unit.label,
                    style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 6),
          Text(
            'Above mean sea level · ${delta24 ?? '—'} in last 24h',
            style: GoogleFonts.poppins(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: AppColors.line),
          const SizedBox(height: 10),
          Row(
            children: [
              _FootStat(label: 'Trend', value: trend),
              _FootStat(label: 'Range high', value: high),
              _FootStat(label: 'Range low', value: low),
              _FootStat(label: 'Next', value: nextLabel),
            ],
          ),
        ],
      ),
    );
  }
}

class _FootStat extends StatelessWidget {
  const _FootStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard({
    required this.station,
    required this.latest,
    required this.unit,
    required this.pending,
    required this.snap,
  });

  final Station? station;
  final Reading? latest;
  final DisplayLengthUnit unit;
  final int pending;
  final AutoSyncSnapshot snap;

  @override
  Widget build(BuildContext context) {
    final calib = station?.calibActualMm == null
        ? 'Not set'
        : unit.formatElevation(station!.calibActualMm);
    final raw = formatDistanceMeters(latest?.distanceMm, unit: unit);
    final sensor = latest == null ? '—' : sensorStatusLabel(latest!.status);
    final freshness = latest == null
        ? '—'
        : formatReadingTimeShort(latest!.measurementTime);
    final cloud = pending == 0
        ? 'Up to date'
        : '$pending pending';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Station diagnostics',
            style: GoogleFonts.poppins(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            'Sensor health, calibration, and sync',
            style: GoogleFonts.poppins(
              fontSize: 12,
              color: AppColors.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _MetricTile(label: 'Raw level', value: raw),
              _MetricTile(label: 'Calibration', value: calib),
              _MetricTile(label: 'Last updated', value: freshness),
              _MetricTile(label: 'Sensor', value: sensor),
              _MetricTile(
                label: 'Cloud',
                value: cloud,
                warn: pending > 0,
              ),
              _MetricTile(
                label: 'Link',
                value: snap.onGateway
                    ? 'SoftAP'
                    : (snap.hasInternet ? 'Internet' : 'None'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    this.warn = false,
  });

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 148,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.panelSoft,
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
                color: AppColors.muted,
              ),
            ),
            Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: warn ? AppColors.warn : AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.snap,
    required this.pending,
    required this.busy,
  });

  final AutoSyncSnapshot snap;
  final int pending;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final isError = snap.phase == AutoSyncPhase.error;
    final Color bg;
    final Color fg;
    final IconData icon;
    final String headline;

    if (isError) {
      bg = AppColors.dangerBg;
      fg = AppColors.danger;
      icon = Icons.error_outline_rounded;
      headline = 'Needs attention';
    } else if (busy) {
      bg = const Color(0xFFE8EEF8);
      fg = const Color(0xFF2F4F7A);
      icon = Icons.sync_rounded;
      headline = snap.stepLabel ?? 'Working…';
    } else if (snap.onGateway && pending > 0) {
      bg = AppColors.warnBg;
      fg = AppColors.warn;
      icon = Icons.cloud_off_outlined;
      headline = 'On SoftAP · cloud waiting';
    } else if (snap.onGateway) {
      bg = AppColors.okBg;
      fg = AppColors.okInk;
      icon = Icons.check_circle_rounded;
      headline = 'Connected to sensor';
    } else if (pending > 0) {
      bg = AppColors.warnBg;
      fg = AppColors.warn;
      icon = Icons.cloud_upload_outlined;
      headline = '$pending waiting to send';
    } else if (snap.hasInternet) {
      bg = AppColors.okBg;
      fg = AppColors.okInk;
      icon = Icons.cloud_done_outlined;
      headline = 'Online';
    } else {
      bg = AppColors.warnBg;
      fg = AppColors.warn;
      icon = Icons.wifi_off_rounded;
      headline = snap.stepLabel ?? 'Waiting';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                if (busy)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                  )
                else
                  Icon(icon, size: 18, color: fg),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    headline,
                    style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            snap.message,
            style: GoogleFonts.poppins(
              color: AppColors.ink,
              fontSize: 13,
              height: 1.35,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (snap.hint != null && snap.hint!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              snap.hint!,
              style: GoogleFonts.poppins(
                color: AppColors.muted,
                fontSize: 12,
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          if (snap.lastError != null && isError) ...[
            const SizedBox(height: 6),
            Text(
              snap.lastError!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                color: AppColors.danger,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.snap,
    required this.busy,
    required this.actionBusy,
    required this.pending,
    required this.onWifi,
    required this.onConnect,
    required this.onSync,
  });

  final AutoSyncSnapshot snap;
  final bool busy;
  final bool actionBusy;
  final int pending;
  final VoidCallback onWifi;
  final VoidCallback onConnect;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final isError = snap.phase == AutoSyncPhase.error;

    if (!snap.wifiOn && !snap.hasInternet) {
      return FilledButton.icon(
        onPressed: busy ? null : onWifi,
        icon: const Icon(Icons.wifi_rounded),
        label: Text(actionBusy ? 'Opening WiFi…' : 'Turn on WiFi'),
      );
    }

    if (isError || pending > 0) {
      return FilledButton.icon(
        onPressed: busy ? null : onSync,
        icon: Icon(
          busy ? Icons.hourglass_top_rounded : Icons.sync_rounded,
        ),
        label: Text(
          busy
              ? 'Working…'
              : (isError ? 'Retry Sync' : 'Sync to cloud'),
        ),
      );
    }

    if (!snap.onGateway) {
      return FilledButton.icon(
        onPressed: busy ? null : onConnect,
        icon: const Icon(Icons.wifi_tethering_rounded),
        label: Text(actionBusy ? 'Connecting…' : 'Connect to sensor'),
      );
    }

    return FilledButton.icon(
      onPressed: busy ? null : onSync,
      icon: const Icon(Icons.sync_rounded),
      label: Text(busy ? 'Working…' : 'Sync now'),
    );
  }
}

class _ChartHeader extends StatelessWidget {
  const _ChartHeader({required this.range, required this.onChanged});
  final _ChartRange range;
  final ValueChanged<_ChartRange> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Level trend',
                style: GoogleFonts.poppins(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'Reservoir elevation',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  color: AppColors.muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: AppColors.panelSoft,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.outline),
          ),
          child: Row(
            children: [
              for (final entry in {
                _ChartRange.h24: '24h',
                _ChartRange.d7: '7d',
              }.entries)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onChanged(entry.key),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: range == entry.key
                          ? AppColors.surface
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      entry.value,
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: range == entry.key
                            ? AppColors.deepTeal
                            : AppColors.muted,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
