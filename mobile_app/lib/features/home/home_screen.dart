import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/utils/water_level_math.dart';
import '../../services/auto_sync_controller.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  AutoSyncController? _auto;
  VoidCallback? _autoListener;
  AutoSyncPhase? _lastPhase;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _auto = ref.read(autoSyncControllerProvider);
      _autoListener = () {
        final phase = _auto!.snapshot.phase;
        final busy = _auto!.snapshot.busy;
        // Refresh home data only when a sync cycle finishes, not while loading.
        if (!busy && _lastPhase != phase) {
          ref.invalidate(dashboardDataProvider);
        }
        if (!busy) _lastPhase = phase;
        // Always rebuild status text.
        if (mounted) setState(() {});
      };
      _auto!.addListener(_autoListener!);
      _auto!.start();
    });
  }

  @override
  void dispose() {
    if (_auto != null && _autoListener != null) {
      _auto!.removeListener(_autoListener!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dash = ref.watch(dashboardDataProvider);
    final auto = ref.watch(autoSyncControllerProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF3F7F5),
      body: SafeArea(
        child: dash.when(
          // Keep prior frame if refreshing — avoid permanent spinner.
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
            final level = data.latest?.waterLevelMm;
            final mountOk = data.station.mountHeightMm != null;
            final measured = data.latest?.measurementTime;

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
                        tooltip: 'Advanced',
                        onPressed: () => context.push('/advanced'),
                        icon: const Icon(Icons.settings_outlined),
                        color: AppColors.muted,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
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
                            'Water level',
                            style: GoogleFonts.manrope(
                              color: Colors.white70,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          const Spacer(),
                          if (!mountOk)
                            Text(
                              'Setup needed',
                              style: GoogleFonts.manrope(
                                color: Colors.white,
                                fontSize: 40,
                                fontWeight: FontWeight.w800,
                                height: 1.05,
                              ),
                            )
                          else if (level == null)
                            Text(
                              'No reading yet',
                              style: GoogleFonts.manrope(
                                color: Colors.white,
                                fontSize: 40,
                                fontWeight: FontWeight.w800,
                                height: 1.05,
                              ),
                            )
                          else ...[
                            Text(
                              (level / 1000).toStringAsFixed(2),
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
                            !mountOk
                                ? 'Open Advanced and enter mounting height once.'
                                : measured == null
                                    ? 'Walk near the station with this phone. Sync runs in the background.'
                                    : 'Updated ${DateFormat('dd MMM, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(measured * 1000))}',
                            style: GoogleFonts.manrope(
                              color: Colors.white70,
                              fontSize: 14,
                              height: 1.35,
                            ),
                          ),
                          if (mountOk && data.latest != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              sensorStatusLabel(data.latest!.status),
                              style: GoogleFonts.manrope(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _StatusCard(
                    busy: auto.snapshot.busy,
                    title: _titleFor(auto.snapshot, data.pendingCount),
                    body: auto.snapshot.message,
                    pending: data.pendingCount,
                    simulated: data.usingMockGateway,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String _titleFor(AutoSyncSnapshot snap, int pending) {
    if (snap.busy) return 'Working…';
    if (snap.phase == AutoSyncPhase.error) return 'Needs attention';
    if (pending > 0) return 'Saved on phone';
    return 'All good';
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.busy,
    required this.title,
    required this.body,
    required this.pending,
    required this.simulated,
  });

  final bool busy;
  final String title;
  final String body;
  final int pending;
  final bool simulated;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFD7E3DE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                )
              else
                Icon(
                  title == 'All good'
                      ? Icons.check_circle_rounded
                      : Icons.info_outline_rounded,
                  color: title == 'All good'
                      ? AppColors.deepTeal
                      : AppColors.muted,
                  size: 20,
                ),
              const SizedBox(width: 10),
              Text(
                title,
                style: GoogleFonts.manrope(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: GoogleFonts.manrope(
              color: AppColors.muted,
              height: 1.35,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (pending > 0) ...[
            const SizedBox(height: 10),
            Text(
              pending == 1
                  ? '1 reading waiting to send when internet is available'
                  : '$pending readings waiting to send when internet is available',
              style: GoogleFonts.manrope(
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
          ],
          if (simulated) ...[
            const SizedBox(height: 10),
            Text(
              'Demo mode is on (Advanced)',
              style: GoogleFonts.manrope(
                color: AppColors.warn,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
