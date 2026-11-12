import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/constants/app_constants.dart';

/// Fallback + Node B config — open from the home gear icon.
class AdvancedScreen extends ConsumerStatefulWidget {
  const AdvancedScreen({super.key});

  @override
  ConsumerState<AdvancedScreen> createState() => _AdvancedScreenState();
}

class _AdvancedScreenState extends ConsumerState<AdvancedScreen> {
  final _intervalController = TextEditingController(text: '30');
  String? _note;
  String? _intervalNote;
  bool _busy = false;
  bool _savingInterval = false;
  /// Value last sent via /config (what Node B is waiting to apply).
  int? _requestedInterval;
  /// pending_interval from /status (Node B side).
  int? _pendingInterval;
  /// latest.interval from /status or last phone reading.
  int? _appliedInterval;

  static const _presets = <(String, int)>[
    ('30s', 30),
    ('1m', 60),
    ('5m', 300),
    ('15m', 900),
  ];

  @override
  void dispose() {
    _intervalController.dispose();
    super.dispose();
  }

  void _setField(int seconds, {bool force = false}) {
    // Don't clobber what the user is typing unless we just applied / loaded.
    if (force || !_intervalController.value.composing.isValid) {
      final text = '$seconds';
      if (_intervalController.text != text) {
        _intervalController.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    }
  }

  Future<void> _refreshStatus({bool overwriteField = false}) async {
    try {
      final status = await ref.read(gatewayClientProvider).getStatus();
      if (!mounted) return;
      final latest = status.latest?.sendIntervalSeconds;
      setState(() {
        _pendingInterval =
            status.pendingInterval > 0 ? status.pendingInterval : null;
        if (latest != null) _appliedInterval = latest;
        // Prefer showing the pending/requested target in the box.
        final show = _pendingInterval ?? _requestedInterval ?? latest;
        if (overwriteField && show != null) {
          _setField(show, force: true);
        }
        if (_pendingInterval != null) {
          _intervalNote =
              'Node B pending ${_pendingInterval}s — applies after Node A’s next send.';
        } else if (_requestedInterval != null &&
            _appliedInterval != null &&
            _requestedInterval != _appliedInterval) {
          _intervalNote =
              'Requested ${_requestedInterval}s · Node B still reporting ${_appliedInterval}s.';
        } else if (_appliedInterval != null) {
          _intervalNote = 'Current interval: ${_appliedInterval}s';
          _requestedInterval = null;
        } else {
          _intervalNote = null;
        }
      });
    } catch (_) {
      // Not on SoftAP — keep local requested value.
      if (!mounted) return;
      setState(() {
        if (_requestedInterval != null) {
          _intervalNote =
              'Requested ${_requestedInterval}s. Rejoin WaterLevel WiFi to confirm.';
        }
      });
    }
  }

  Future<void> _applyInterval(int seconds) async {
    final clamped = seconds.clamp(10, 3600);
    setState(() {
      _savingInterval = true;
      _requestedInterval = clamped;
      _pendingInterval = clamped;
      _intervalNote = 'Sending /config?interval=$clamped…';
    });
    _setField(clamped, force: true);
    try {
      await ref.read(gatewayClientProvider).setSendInterval(clamped);
      if (!mounted) return;
      setState(() {
        _intervalNote =
            'Sent $clamped s. Pending until Node A’s next send.';
      });
      // Refresh status but keep the requested value in the field.
      await _refreshStatus(overwriteField: false);
      _setField(clamped, force: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _intervalNote =
            'Could not set interval. Join WaterLevel WiFi first.\n$e';
      });
    } finally {
      if (mounted) setState(() => _savingInterval = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final latest = ref
          .read(dashboardDataProvider)
          .asData
          ?.value
          .latest
          ?.sendIntervalSeconds;
      if (latest != null) {
        _appliedInterval = latest;
        _setField(latest, force: true);
      }
      _refreshStatus(overwriteField: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final displayApplied = _appliedInterval;
    final displayPending = _pendingInterval ?? _requestedInterval;
    final selected = int.tryParse(_intervalController.text.trim());

    return Scaffold(
      backgroundColor: const Color(0xFFF3F7F5),
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: const Color(0xFFF3F7F5),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          Text(
            'Sensor interval and manual WiFi connect.',
            style: GoogleFonts.manrope(
              color: AppColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Node A send interval',
                    style: GoogleFonts.manrope(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (displayApplied != null)
                        'Applied on readings: ${displayApplied}s',
                      if (displayPending != null &&
                          displayPending != displayApplied)
                        'Target / pending: ${displayPending}s',
                      if (displayApplied == null && displayPending == null)
                        'Join WaterLevel WiFi, then set 10–3600 seconds.',
                    ].join(' · '),
                    style: const TextStyle(color: AppColors.muted, height: 1.35),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in _presets)
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: selected == p.$2
                                ? AppColors.deepTeal.withValues(alpha: 0.12)
                                : null,
                            side: BorderSide(
                              color: selected == p.$2
                                  ? AppColors.deepTeal
                                  : AppColors.line,
                              width: selected == p.$2 ? 2 : 1,
                            ),
                          ),
                          onPressed: _savingInterval
                              ? null
                              : () => _applyInterval(p.$2),
                          child: Text(p.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _intervalController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Custom (seconds)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _savingInterval
                            ? null
                            : () {
                                final v = int.tryParse(
                                  _intervalController.text.trim(),
                                );
                                if (v == null || v < 10 || v > 3600) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Enter 10–3600 seconds'),
                                    ),
                                  );
                                  return;
                                }
                                _applyInterval(v);
                              },
                        child: _savingInterval
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Apply'),
                      ),
                    ],
                  ),
                  if (_intervalNote != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _intervalNote!,
                      style: GoogleFonts.manrope(fontWeight: FontWeight.w600),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connect manually',
                    style: GoogleFonts.manrope(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Join SSID ${AppConstants.gatewaySsid} (password ${AppConstants.gatewayPassword}) so the phone can pull readings from the ESP.',
                    style: const TextStyle(color: AppColors.muted, height: 1.35),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            setState(() {
                              _busy = true;
                              _note = null;
                            });
                            final net = ref.read(networkServiceProvider);
                            final msg =
                                await net.requestGatewayWifiConnection();
                            await ref
                                .read(autoSyncControllerProvider)
                                .runCycle(force: true);
                            ref.invalidate(dashboardDataProvider);
                            await _refreshStatus(overwriteField: false);
                            if (!mounted) return;
                            setState(() {
                              _busy = false;
                              _note = msg;
                            });
                          },
                    child: Text(
                      _busy ? 'Connecting…' : 'Connect to WaterLevel WiFi',
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_note != null) ...[
            const SizedBox(height: 14),
            Text(
              _note!,
              style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
            ),
          ],
        ],
      ),
    );
  }
}
