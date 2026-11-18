import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/constants/app_constants.dart';
import '../../core/utils/water_level_math.dart';
import '../../services/auto_sync_controller.dart';

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
        if ((_wasBusy && !busy) || (!_wasOnGateway && connectedNow)) {
          ref.invalidate(dashboardDataProvider);
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

  Future<void> _connectWaterLevel() async {
    final network = ref.read(networkServiceProvider);
    final auto = ref.read(autoSyncControllerProvider);
    _auto ??= auto;

    setState(() => _actionBusy = true);
    try {
      // Already on SoftAP (user joined from system WiFi) — don't sit on Connecting…
      if (await network.isOnGatewayFast()) {
        await auto.refreshConnectionStatus();
        await auto.runCycle(force: true);
        ref.invalidate(dashboardDataProvider);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Connected to WaterLevel')),
          );
        }
        return;
      }

      final msg = await network.requestGatewayWifiConnection();
      await ref.read(auditLogServiceProvider).info(
            'Connect to WaterLevel requested',
            category: 'network',
            detail: msg,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Approve the phone prompt for “${AppConstants.gatewaySsid}”…',
            ),
          ),
        );
      }

      // Short poll only — status timer + SoftAP events keep updating the UI.
      var connected = false;
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (!mounted) return;
        final onGateway = await network.isOnGatewayFast();
        await auto.refreshConnectionStatus();
        if (onGateway || auto.snapshot.onGateway) {
          connected = true;
          break;
        }
        if (mounted) setState(() {});
      }

      if (connected) {
        await auto.runCycle(force: true);
        ref.invalidate(dashboardDataProvider);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              connected
                  ? 'Connected to WaterLevel'
                  : 'If the phone shows WaterLevel WiFi, tap Sync now',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _syncNow() async {
    final auto = ref.read(autoSyncControllerProvider);
    final network = ref.read(networkServiceProvider);
    _auto ??= auto;
    if (!auto.snapshot.wifiOn) {
      await _turnWifiOn();
      return;
    }
    // Re-probe SoftAP so Sync works even when the banner lagged behind.
    await network.isOnGatewayFast();
    await auto.refreshConnectionStatus();
    await auto.runCycle(force: true);
    ref.invalidate(dashboardDataProvider);
  }

  @override
  Widget build(BuildContext context) {
    final dash = ref.watch(dashboardDataProvider);
    final auto = ref.watch(autoSyncControllerProvider);
    // Keep listener attached if provider instance ever changes.
    if (!identical(_auto, auto)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _attachAutoSync());
    }
    final snap = auto.snapshot;

    return Scaffold(
      backgroundColor: const Color(0xFFF3F7F5),
      body: SafeArea(
        child: dash.when(
          skipLoadingOnReload: true,
          skipLoadingOnRefresh: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('$e', textAlign: TextAlign.center),
            ),
          ),
          data: (data) {
            final latest = data.latest;
            final level = latest?.waterLevelMm ??
                calculateWaterLevelMm(
                  mountHeightMm: data.station.mountHeightMm,
                  distanceMm: latest?.distanceMm,
                );
            final measured = latest?.measurementTime;
            final levelLabel =
                level == null ? '—' : (level / 1000).toStringAsFixed(2);
            final pending =
                snap.pendingCount > 0 ? snap.pendingCount : data.pendingCount;

            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        'WaterLevel',
                        style: GoogleFonts.manrope(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.8,
                          color: AppColors.ink,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Audit log',
                        onPressed: () => context.push('/audit'),
                        icon: const Icon(Icons.receipt_long_outlined),
                        color: AppColors.muted,
                      ),
                      IconButton(
                        tooltip: 'Settings',
                        onPressed: () => context.push('/advanced'),
                        icon: const Icon(Icons.settings_outlined),
                        color: AppColors.muted,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _ConnectionBanner(
                    wifiOn: snap.wifiOn,
                    connected: snap.onGateway || data.usingMockGateway,
                    hasInternet: snap.hasInternet,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(28),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFF0B3D34),
                            Color(0xFF0A5C4B),
                            Color(0xFF149276),
                          ],
                        ),
                      ),
                      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Current water level',
                            style: GoogleFonts.manrope(
                              color: Colors.white70,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          const Spacer(),
                          if (latest == null)
                            Text(
                              'No reading yet',
                              style: GoogleFonts.manrope(
                                color: Colors.white,
                                fontSize: 36,
                                fontWeight: FontWeight.w800,
                                height: 1.05,
                              ),
                            )
                          else ...[
                            Text(
                              levelLabel,
                              style: GoogleFonts.manrope(
                                color: Colors.white,
                                fontSize: 72,
                                fontWeight: FontWeight.w800,
                                height: 0.95,
                                letterSpacing: -2,
                              ),
                            ),
                            Text(
                              'metres',
                              style: GoogleFonts.manrope(
                                color: Colors.white70,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          const Spacer(),
                          Text(
                            measured == null
                                ? 'Connect to WaterLevel WiFi near the station to collect readings.'
                                : 'Updated ${DateFormat('dd MMM, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(measured * 1000))}',
                            style: GoogleFonts.manrope(
                              color: Colors.white70,
                              fontSize: 14,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _StatusBar(
                    busy: snap.busy,
                    isError: snap.phase == AutoSyncPhase.error,
                    title: snap.stepLabel ??
                        (snap.onGateway
                            ? 'Connected'
                            : snap.wifiOn
                                ? 'Ready'
                                : 'WiFi off'),
                    message: snap.message,
                    pending: pending,
                    detail: snap.lastError,
                    onOpenAudit: () => context.push('/audit'),
                  ),
                  const SizedBox(height: 12),
                  if (!snap.wifiOn)
                    FilledButton.icon(
                      onPressed: _actionBusy ? null : _turnWifiOn,
                      icon: _actionBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.wifi_rounded),
                      label: Text(
                        _actionBusy ? 'Opening WiFi…' : 'Turn on WiFi',
                      ),
                    )
                  else if (!snap.onGateway && !data.usingMockGateway)
                    FilledButton.icon(
                      onPressed: (_actionBusy || snap.busy)
                          ? null
                          : _connectWaterLevel,
                      icon: const Icon(Icons.wifi_tethering_rounded),
                      label: Text(
                        _actionBusy
                            ? 'Connecting…'
                            : 'Connect to WaterLevel WiFi',
                      ),
                    )
                  else
                    FilledButton.icon(
                      onPressed: null,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.okBg,
                        disabledBackgroundColor: AppColors.okBg,
                        disabledForegroundColor: AppColors.deepTeal,
                      ),
                      icon: const Icon(Icons.check_circle_rounded),
                      label: const Text('Connected to WaterLevel'),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: snap.busy || _actionBusy ? null : _syncNow,
                    child: Text(snap.busy ? 'Working…' : 'Sync now'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({
    required this.wifiOn,
    required this.connected,
    required this.hasInternet,
  });

  final bool wifiOn;
  final bool connected;
  final bool hasInternet;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final IconData icon;
    final String label;

    if (connected) {
      bg = AppColors.okBg;
      fg = AppColors.deepTeal;
      icon = Icons.check_circle_rounded;
      label = 'Connected to WaterLevel';
    } else if (!wifiOn) {
      bg = AppColors.warnBg;
      fg = AppColors.warn;
      icon = Icons.wifi_off_rounded;
      label = 'WiFi is off';
    } else if (hasInternet) {
      bg = const Color(0xFFE8EEF8);
      fg = const Color(0xFF2F4F7A);
      icon = Icons.cloud_outlined;
      label = 'Online · not on WaterLevel WiFi';
    } else {
      bg = AppColors.warnBg;
      fg = AppColors.warn;
      icon = Icons.wifi_rounded;
      label = 'WiFi on · not connected to WaterLevel';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.manrope(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.busy,
    required this.isError,
    required this.title,
    required this.message,
    required this.pending,
    required this.detail,
    required this.onOpenAudit,
  });

  final bool busy;
  final bool isError;
  final String title;
  final String message;
  final int pending;
  final String? detail;
  final VoidCallback onOpenAudit;

  @override
  Widget build(BuildContext context) {
    final accent = isError
        ? AppColors.danger
        : busy
            ? AppColors.deepTeal
            : AppColors.muted;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isError
              ? AppColors.danger.withValues(alpha: 0.35)
              : AppColors.line,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (busy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: accent,
                  ),
                )
              else
                Icon(
                  isError
                      ? Icons.error_outline_rounded
                      : Icons.info_outline_rounded,
                  size: 18,
                  color: accent,
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.manrope(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              TextButton(
                onPressed: onOpenAudit,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.deepTeal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Log',
                  style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: GoogleFonts.manrope(
              color: AppColors.muted,
              height: 1.35,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          if (detail != null && detail!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              detail!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.manrope(
                color: AppColors.danger,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: pending == 0 ? AppColors.okBg : AppColors.warnBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              pending == 0
                  ? 'Cloud status: everything pushed'
                  : 'Cloud status: $pending pending upload',
              style: GoogleFonts.manrope(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: pending == 0 ? AppColors.deepTeal : AppColors.warn,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
