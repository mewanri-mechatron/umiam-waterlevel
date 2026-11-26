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
import '../../database/app_database.dart';
import '../../models/reading.dart';
import '../../models/station.dart';
import '../../services/auto_sync_controller.dart';
import '../../services/network_service.dart';
import '../../services/weather_service.dart';
import '../../widgets/extra_charts.dart';
import '../../widgets/level_chart.dart';
import '../../widgets/meecl_branding.dart';
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
  final _weather = WeatherService();
  List<DailyRain> _rainDaily = const [];
  bool _weatherLoading = false;
  String? _weatherError;

  /// Re-reads local SQLite so a reading saved by the background service shows
  /// up without any tap, and "x min ago" labels stay current.
  Timer? _localRefreshTimer;

  /// Storage / battery / notification state of this phone, for the banners.
  PhoneStatus? _phone;
  Timer? _phoneTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attachAutoSync();
      unawaited(_loadWeather());
      unawaited(_loadPhoneStatus());
    });
    _localRefreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      unawaited(ref.read(dashboardDataProvider.notifier).refresh());
    });
    _phoneTimer = Timer.periodic(
      const Duration(minutes: 3),
      (_) => unawaited(_loadPhoneStatus()),
    );
  }

  Future<void> _loadPhoneStatus() async {
    if (!mounted) return;
    final status = await ref.read(networkServiceProvider).phoneStatus();
    if (!mounted || status == null) return;
    setState(() => _phone = status);
  }

  Future<void> _fixPhoneSetting(String which) async {
    await ref.read(networkServiceProvider).openPhoneSettings(which);
  }

  List<Widget> _phoneAlerts() {
    final p = _phone;
    if (p == null) return const [];
    return [
      if (p.storageLow)
        const _PhoneAlert(
          danger: true,
          icon: Icons.sd_storage_outlined,
          title: 'Phone storage is almost full',
          message: 'Delete some photos or videos so new readings can be saved.',
        ),
      if (!p.batteryUnrestricted)
        _PhoneAlert(
          icon: Icons.battery_alert_rounded,
          title: 'Phone may stop this app',
          message: 'Tap Fix, then choose “Allow”.',
          onFix: () => _fixPhoneSetting('battery'),
        ),
      if (!p.notificationsOn)
        _PhoneAlert(
          icon: Icons.notifications_off_outlined,
          title: 'Notifications are off',
          message: 'Tap Fix and turn notifications on.',
          onFix: () => _fixPhoneSetting('notifications'),
        ),
      if (!p.locationPermission)
        _PhoneAlert(
          icon: Icons.location_off_outlined,
          title: 'Location permission is off',
          message:
              'Needed to find the sensor WiFi. Tap Fix → Permissions → '
              'Location → Allow.',
          onFix: () => _fixPhoneSetting('app'),
        ),
    ];
  }

  Future<void> _loadWeather() async {
    if (!mounted) return;
    setState(() {
      _weatherLoading = true;
      _weatherError = null;
    });
    try {
      final w = await _weather.fetchUmiam();
      if (!mounted) return;
      setState(() {
        _rainDaily = w.daily;
        _weatherLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _weatherLoading = false;
        _weatherError = 'Rainfall not available right now';
      });
    }
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
          _refreshData();
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
      _refreshData();
      unawaited(_loadPhoneStatus());
    }
  }

  @override
  void dispose() {
    _localRefreshTimer?.cancel();
    _phoneTimer?.cancel();
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
      await ref
          .read(auditLogServiceProvider)
          .info('Connect to sensor WiFi', category: 'network', detail: msg);

      var connected = false;
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (!mounted) return;
        final onGateway = await network.isOnGatewayFast(allowHttpProbe: false);
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
              'Could not connect. Go near the sensor, open WiFi and choose '
              '“${AppConstants.gatewaySsid}”.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  void _refreshData() {
    if (!mounted) return;
    unawaited(ref.read(dashboardDataProvider.notifier).refresh());
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

    // Keep the last good data on screen through reloads and errors.
    final data = dash.valueOrNull;
    final station = data?.station;
    final latest = data?.latest;
    final recent = data?.recent ?? const <Reading>[];
    final pending = snap.pendingCount > 0
        ? snap.pendingCount
        : (data?.pendingCount ?? 0);
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

    final rangeRows = _filterChart(recent, _chartRange);
    final chartRows = _downsample(rangeRows, 360);
    final delta24 = _delta24h(recent, station, unit);
    final rangeStats = _rangeStats(rangeRows, station, unit);
    final lateness = _lateness(latest);
    final stale = _isStale(latest);
    final alerts = _phoneAlerts();

    return Scaffold(
      backgroundColor: AppColors.mist,
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.deepTeal,
          onRefresh: () async {
            await Future.wait([_syncNow(), _loadWeather()]);
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const MeeclBrandHeader(compact: true),
                    const SizedBox(height: 16),
                    const UnitPicker(dense: true),
                    const SizedBox(height: 20),
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
                      stale: stale,
                      lateBySeconds: lateness.lateBySeconds,
                    ),
                    for (final alert in alerts) ...[
                      const SizedBox(height: 12),
                      alert,
                    ],
                    const SizedBox(height: 16),
                    _StatusActionCard(
                      snap: snap,
                      pending: pending,
                      busy: busy,
                      actionBusy: _actionBusy,
                      stale: stale,
                      lateBySeconds: lateness.lateBySeconds,
                      cloud: data?.cloud,
                      onWifi: _turnWifiOn,
                      onConnect: _connectSensor,
                      onSync: _syncNow,
                    ),
                    const SizedBox(height: 16),
                    _DiagnosticsCard(
                      station: station,
                      latest: latest,
                      unit: unit,
                      snap: snap,
                      phone: _phone,
                      cloud: data?.cloud,
                      pending: pending,
                    ),
                    const SizedBox(height: 20),
                    ChartCardShell(
                      title: 'Level trend',
                      subtitle: 'Reservoir elevation profile',
                      trailing: _ChartRangeSeg(
                        range: _chartRange,
                        onChanged: (r) => setState(() => _chartRange = r),
                      ),
                      child: LevelChart(
                        readings: chartRows,
                        station: station,
                        unit: unit,
                        height: 200,
                      ),
                    ),
                    const SizedBox(height: 20),
                    ChartCardShell(
                      title: 'Trend & Forecast',
                      subtitle: 'Observed level + rain near the dam',
                      child: Column(
                        children: [
                          ForecastChart(
                            readings: chartRows,
                            station: station,
                            unit: unit,
                            height: 180,
                          ),
                          const SizedBox(height: 16),
                          RainBarChart(
                            daily: _rainDaily,
                            loading: _weatherLoading,
                            error: _weatherError,
                            height: 140,
                          ),
                        ],
                      ),
                    ),
                    if (dash.hasError && data == null) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Could not read saved readings yet · retrying automatically',
                        style: GoogleFonts.poppins(
                          color: AppColors.danger,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                  ],
                ),
              ),
              const MeeclSiteFooter(),
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
    final filtered = recent.where((r) => r.measurementTime >= from).toList();
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
    final d =
        unit.fromElevationStored(newest) - unit.fromElevationStored(oldest);
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

  /// Even-stride thinning so charts stay smooth with thousands of rows.
  /// Always keeps the newest point.
  List<Reading> _downsample(List<Reading> rows, int maxPoints) {
    if (rows.length <= maxPoints) return rows;
    final step = rows.length / maxPoints;
    final out = <Reading>[
      for (var i = 0; i < maxPoints - 1; i++) rows[(i * step).floor()],
      rows.last,
    ];
    return out;
  }

  /// How late we are vs the sensor send interval.
  /// 0 = next reading not due yet; otherwise seconds past the expected time.
  ({int lateBySeconds, int intervalSeconds, bool overdue}) _lateness(
    Reading? latest,
  ) {
    if (latest == null) {
      return (lateBySeconds: 0, intervalSeconds: 3600, overdue: false);
    }
    final interval = latest.sendIntervalSeconds.clamp(10, 86400);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final dueAt = latest.measurementTime + interval;
    final late = now - dueAt;
    return (
      lateBySeconds: late > 0 ? late : 0,
      intervalSeconds: interval,
      overdue: late > 0,
    );
  }

  /// Overdue by more than half a send interval (or 15 min) → warn.
  bool _isStale(Reading? latest) {
    final l = _lateness(latest);
    if (!l.overdue) return false;
    final grace = (l.intervalSeconds ~/ 2).clamp(15 * 60, 3 * 3600);
    return l.lateBySeconds >= grace;
  }

  /// Matches web dashboard countdown / late-by wording.
  String _nextReadingLabel(Reading? latest) {
    if (latest == null) return '—';
    final l = _lateness(latest);
    if (l.overdue) return 'Late by ${_formatSpan(l.lateBySeconds)}';
    final remain =
        (latest.measurementTime + l.intervalSeconds) -
        (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    if (remain <= 0) return 'Due now';
    final h = remain ~/ 3600;
    final m = (remain % 3600) ~/ 60;
    final s = remain % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

String _cloudBehindLabel(CloudSyncInfo? cloud, int pending) {
  if (cloud == null) return '—';
  if (cloud.newestLocalTime == null) return '—';
  if (!cloud.hasCloudData) {
    return pending > 0 ? 'No cloud data yet' : '—';
  }
  final lag = cloud.lagSeconds;
  if (lag <= 0) return 'Caught up';
  return _formatSpan(lag);
}

enum _ChartRange { h24, d7 }

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
    required this.stale,
    required this.lateBySeconds,
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
  final bool stale;
  final int lateBySeconds;

  static const _soft = Color(0xFF91CFBE);
  static const _mid = Color(0xFF185A4D);

  @override
  Widget build(BuildContext context) {
    final date = measured == null
        ? '—'
        : DateFormat(
            'dd MMM yyyy',
          ).format(DateTime.fromMillisecondsSinceEpoch(measured! * 1000));
    final time = measured == null
        ? '—'
        : DateFormat(
            'h:mm a',
          ).format(DateTime.fromMillisecondsSinceEpoch(measured! * 1000));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      decoration: BoxDecoration(
        color: AppColors.deepTeal,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'CURRENT WATER LEVEL',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: _soft,
                ),
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    date,
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: _soft,
                    ),
                  ),
                  Text(
                    time,
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (loading && levelLabel == null)
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Colors.white,
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
                    color: Colors.white,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 10, bottom: 6),
                  child: Text(
                    unit.label,
                    style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: _soft,
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 12),
          Text.rich(
            TextSpan(
              style: GoogleFonts.poppins(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: _soft,
              ),
              children: [
                const TextSpan(text: 'Above mean sea level · '),
                TextSpan(
                  text: delta24 ?? '—',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const TextSpan(text: ' in last 24h'),
              ],
            ),
          ),
          if (lateBySeconds > 0) ...[
            const SizedBox(height: 10),
            Text(
              'Reading late by ${_formatSpan(lateBySeconds)}'
              '${stale ? ' · check sensor power' : ''}',
              style: GoogleFonts.poppins(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: stale ? const Color(0xFFFFDAD6) : const Color(0xFFFFE7A3),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Container(height: 1, color: _mid),
          const SizedBox(height: 14),
          // 2×2 like the web hero so long "Late by …" labels fit.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FootStat(label: 'Trend', value: trend, onTeal: true),
              const SizedBox(width: 12),
              _FootStat(label: 'Range high', value: high, onTeal: true),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FootStat(label: 'Range low', value: low, onTeal: true),
              const SizedBox(width: 12),
              _FootStat(label: 'Next reading', value: nextLabel, onTeal: true),
            ],
          ),
        ],
      ),
    );
  }
}

String _formatSpan(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  if (s < 60) return 'under 1 min';
  final mins = s ~/ 60;
  if (mins < 60) return '$mins min';
  final hours = mins ~/ 60;
  if (hours < 24) {
    final m = mins % 60;
    return m == 0 ? '$hours h' : '$hours h $m min';
  }
  final days = hours ~/ 24;
  final h = hours % 24;
  return h == 0 ? '$days d' : '$days d $h h';
}

String _clock(int epochSeconds) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
  final now = DateTime.now();
  final sameDay =
      dt.year == now.year && dt.month == now.month && dt.day == now.day;
  return sameDay
      ? DateFormat('h:mm a').format(dt)
      : DateFormat('d MMM, h:mm a').format(dt);
}

/// Status line + one primary button + a short sync note (replaces three cards).
class _StatusActionCard extends StatelessWidget {
  const _StatusActionCard({
    required this.snap,
    required this.pending,
    required this.busy,
    required this.actionBusy,
    required this.stale,
    required this.lateBySeconds,
    required this.cloud,
    required this.onWifi,
    required this.onConnect,
    required this.onSync,
  });

  final AutoSyncSnapshot snap;
  final int pending;
  final bool busy;
  final bool actionBusy;
  final bool stale;
  final int lateBySeconds;
  final CloudSyncInfo? cloud;
  final VoidCallback onWifi;
  final VoidCallback onConnect;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final isError = snap.phase == AutoSyncPhase.error;
    final Color fg;
    final IconData icon;
    final String headline;

    if (isError) {
      fg = AppColors.danger;
      icon = Icons.error_outline_rounded;
      headline = 'Needs attention';
    } else if (busy) {
      fg = const Color(0xFF2F4F7A);
      icon = Icons.sync_rounded;
      headline = snap.stepLabel ?? 'Working…';
    } else if (stale || lateBySeconds > 0) {
      fg = stale ? AppColors.danger : AppColors.warn;
      icon = Icons.schedule_rounded;
      headline = lateBySeconds > 0
          ? 'Reading late by ${_formatSpan(lateBySeconds)}'
          : 'Waiting for next reading';
    } else if (snap.onGateway) {
      fg = AppColors.okInk;
      icon = Icons.check_circle_rounded;
      headline = 'Connected to sensor';
    } else if (pending > 0) {
      fg = AppColors.warn;
      icon = Icons.cloud_upload_outlined;
      headline = '$pending waiting to send';
    } else if (snap.hasInternet) {
      fg = AppColors.muted;
      icon = Icons.wifi_find_rounded;
      headline = 'Ready · not on sensor WiFi';
    } else {
      fg = AppColors.warn;
      icon = Icons.wifi_off_rounded;
      headline = snap.stepLabel ?? 'Waiting';
    }

    final behind = _cloudBehindLabel(cloud, pending);
    final String syncNote;
    if (pending > 0 && (cloud?.lagSeconds ?? 0) > 0) {
      syncNote = 'Cloud behind by $behind · $pending waiting to send';
    } else if (pending > 0) {
      syncNote = '$pending waiting to send · cloud: $behind';
    } else if (stale) {
      syncNote = 'Cloud: $behind · last reading is old';
    } else {
      syncNote = 'Cloud: $behind';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (busy)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                )
              else
                Icon(icon, size: 20, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  headline,
                  style: GoogleFonts.poppins(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            snap.message,
            style: GoogleFonts.poppins(
              color: AppColors.ink,
              fontSize: 14,
              height: 1.4,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (snap.hint != null && snap.hint!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              snap.hint!,
              style: GoogleFonts.poppins(
                color: AppColors.muted,
                fontSize: 13,
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: 14),
          _buildAction(isError),
          const SizedBox(height: 12),
          Text(
            syncNote,
            style: GoogleFonts.poppins(
              color: AppColors.muted,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAction(bool isError) {
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
        icon: Icon(busy ? Icons.hourglass_top_rounded : Icons.sync_rounded),
        label: Text(
          busy ? 'Please wait…' : (isError ? 'Try again' : 'Send now'),
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
      label: Text(busy ? 'Please wait…' : 'Read sensor now'),
    );
  }
}

class _FootStat extends StatelessWidget {
  const _FootStat({
    required this.label,
    required this.value,
    this.onTeal = false,
  });
  final String label;
  final String value;
  final bool onTeal;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: GoogleFonts.poppins(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: onTeal ? const Color(0xFF91CFBE) : AppColors.muted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 2,
            softWrap: true,
            overflow: TextOverflow.visible,
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.25,
              color: onTeal ? Colors.white : AppColors.ink,
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
    required this.snap,
    required this.phone,
    required this.cloud,
    required this.pending,
  });

  final Station? station;
  final Reading? latest;
  final DisplayLengthUnit unit;
  final AutoSyncSnapshot snap;
  final PhoneStatus? phone;
  final CloudSyncInfo? cloud;
  final int pending;

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
    final interval = latest?.sendIntervalSeconds;
    final intervalLabel = interval == null
        ? '—'
        : interval >= 3600 && interval % 3600 == 0
        ? '${interval ~/ 3600} h'
        : interval >= 60
        ? '${interval ~/ 60} min'
        : '$interval s';
    final newestLocal = cloud?.newestLocalTime;
    final newestCloud = cloud?.newestCloudTime;
    final behind = _cloudBehindLabel(cloud, pending);
    final lag = cloud?.lagSeconds ?? 0;

    final p = phone;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.outline),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
          childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: Text(
            'Station diagnostics',
            style: GoogleFonts.poppins(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
          subtitle: Text(
            'Sensor health, calibration, and sync',
            style: GoogleFonts.poppins(
              fontSize: 13,
              color: AppColors.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final tileW = (constraints.maxWidth - 12) / 2;
                Widget tile(String label, String value, {bool warn = false}) {
                  return SizedBox(
                    width: tileW,
                    child: _MetricTile(label: label, value: value, warn: warn),
                  );
                }

                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    tile('Raw level', raw),
                    tile('Calibration', calib),
                    tile('Last updated', freshness),
                    tile('Interval', intervalLabel),
                    tile('Sensor', sensor),
                    tile(
                      'Link',
                      snap.onGateway
                          ? 'Sensor WiFi'
                          : (snap.hasInternet ? 'Internet' : 'None'),
                    ),
                    tile(
                      'Newest on phone',
                      newestLocal == null ? '—' : _clock(newestLocal),
                    ),
                    tile(
                      'Newest in cloud',
                      newestCloud == null ? '—' : _clock(newestCloud),
                      warn: pending > 0,
                    ),
                    tile(
                      'Waiting to send',
                      pending == 0
                          ? 'None'
                          : '$pending reading${pending == 1 ? '' : 's'}',
                      warn: pending > 0,
                    ),
                    tile(
                      'Cloud behind by',
                      behind,
                      warn: lag > 0 ||
                          (pending > 0 && !(cloud?.hasCloudData ?? false)),
                    ),
                    if (p != null) ...[
                      tile('Phone', p.name),
                      tile('Phone ID', p.deviceId),
                      tile('Android · app', '${p.android} · ${p.appVersion}'),
                      tile(
                        'Free storage',
                        p.freeStorageMb < 0 ? '—' : '${p.freeStorageMb} MB',
                        warn: p.storageLow,
                      ),
                    ],
                    if (snap.lastError != null)
                      tile('Last error', snap.lastError!),
                  ],
                );
              },
            ),
          ],
        ),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.panelSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: warn ? AppColors.warn : AppColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _PhoneAlert extends StatelessWidget {
  const _PhoneAlert({
    required this.icon,
    required this.title,
    required this.message,
    this.danger = false,
    this.onFix,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool danger;
  final VoidCallback? onFix;

  @override
  Widget build(BuildContext context) {
    final fg = danger ? AppColors.danger : AppColors.warn;
    final bg = danger ? AppColors.dangerBg : AppColors.warnBg;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
                Text(
                  message,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                    color: AppColors.ink,
                  ),
                ),
              ],
            ),
          ),
          if (onFix != null) ...[
            const SizedBox(width: 6),
            FilledButton(
              onPressed: onFix,
              style: FilledButton.styleFrom(
                backgroundColor: fg,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: const Size(64, 40),
              ),
              child: const Text('Fix'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChartRangeSeg extends StatelessWidget {
  const _ChartRangeSeg({required this.range, required this.onChanged});
  final _ChartRange range;
  final ValueChanged<_ChartRange> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFECEEEC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in {
            _ChartRange.h24: '24h',
            _ChartRange.d7: '7d',
          }.entries)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => onChanged(entry.key),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: range == entry.key
                      ? AppColors.surface
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: range == entry.key
                      ? const [
                          BoxShadow(
                            color: Color(0x0A191C1B),
                            blurRadius: 2,
                            offset: Offset(0, 1),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  entry.value,
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: range == entry.key
                        ? AppColors.deepTeal
                        : AppColors.muted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
