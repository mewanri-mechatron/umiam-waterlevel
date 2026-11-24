import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/constants/app_constants.dart';
import '../../widgets/unit_picker.dart';

enum _IntervalUnit { seconds, minutes, hours }

/// Sensor interval and manual connect — calibration is on Setup.
class AdvancedScreen extends ConsumerStatefulWidget {
  const AdvancedScreen({super.key});

  @override
  ConsumerState<AdvancedScreen> createState() => _AdvancedScreenState();
}

class _AdvancedScreenState extends ConsumerState<AdvancedScreen> {
  final _valueController = TextEditingController(text: '30');
  _IntervalUnit _unit = _IntervalUnit.seconds;
  String? _note;
  String? _intervalNote;
  bool _busy = false;
  bool _savingInterval = false;
  int? _requestedInterval;
  int? _pendingInterval;
  int? _appliedInterval;

  static const _presets = <(String, int)>[
    ('30 sec', 30),
    ('1 min', 60),
    ('5 min', 300),
    ('15 min', 900),
    ('30 min', 1800),
    ('1 hour', 3600),
  ];

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  String _friendlySeconds(int seconds) {
    if (seconds % 3600 == 0) return '${seconds ~/ 3600} hour${seconds == 3600 ? '' : 's'}';
    if (seconds % 60 == 0) {
      final m = seconds ~/ 60;
      return '$m min';
    }
    return '$seconds sec';
  }

  void _setFieldFromSeconds(int seconds, {bool force = false}) {
    if (!force && _valueController.value.composing.isValid) return;
    late final String text;
    late final _IntervalUnit unit;
    if (seconds >= 3600 && seconds % 3600 == 0) {
      unit = _IntervalUnit.hours;
      text = '${seconds ~/ 3600}';
    } else if (seconds >= 60 && seconds % 60 == 0) {
      unit = _IntervalUnit.minutes;
      text = '${seconds ~/ 60}';
    } else {
      unit = _IntervalUnit.seconds;
      text = '$seconds';
    }
    setState(() => _unit = unit);
    if (_valueController.text != text) {
      _valueController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  int? _secondsFromField() {
    final raw = double.tryParse(_valueController.text.trim());
    if (raw == null || raw <= 0) return null;
    switch (_unit) {
      case _IntervalUnit.seconds:
        return raw.round();
      case _IntervalUnit.minutes:
        return (raw * 60).round();
      case _IntervalUnit.hours:
        return (raw * 3600).round();
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
        final show = _pendingInterval ?? _requestedInterval ?? latest;
        if (overwriteField && show != null) {
          _setFieldFromSeconds(show, force: true);
        }
        if (_pendingInterval != null) {
          _intervalNote =
              'Pending ${_friendlySeconds(_pendingInterval!)} — applies after next send.';
        } else if (_requestedInterval != null &&
            _appliedInterval != null &&
            _requestedInterval != _appliedInterval) {
          _intervalNote =
              'Requested ${_friendlySeconds(_requestedInterval!)} · '
              'sensor still ${_friendlySeconds(_appliedInterval!)}.';
        } else if (_appliedInterval != null) {
          _intervalNote =
              'Current: ${_friendlySeconds(_appliedInterval!)}';
          _requestedInterval = null;
        } else {
          _intervalNote = null;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (_requestedInterval != null) {
          _intervalNote =
              'Requested ${_friendlySeconds(_requestedInterval!)}. '
              'Join sensor WiFi to confirm.';
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
      _intervalNote = 'Sending ${_friendlySeconds(clamped)}…';
    });
    _setFieldFromSeconds(clamped, force: true);
    try {
      await ref.read(gatewayClientProvider).setSendInterval(clamped);
      if (!mounted) return;
      setState(() {
        _intervalNote =
            'Sent ${_friendlySeconds(clamped)}. Applies after next send.';
      });
      await _refreshStatus(overwriteField: false);
      _setFieldFromSeconds(clamped, force: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _intervalNote =
            'Could not set. Join sensor WiFi first.\n$e';
      });
    } finally {
      if (mounted) setState(() => _savingInterval = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final latest = ref
          .read(dashboardDataProvider)
          .asData
          ?.value
          .latest
          ?.sendIntervalSeconds;
      if (latest != null) {
        _appliedInterval = latest;
        _setFieldFromSeconds(latest, force: true);
      }
      await _refreshStatus(overwriteField: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final displayApplied = _appliedInterval;
    final displayPending = _pendingInterval ?? _requestedInterval;
    final selectedSeconds = _secondsFromField();

    return Scaffold(
      backgroundColor: AppColors.mist,
      appBar: AppBar(
        title: const Text('Advanced'),
        backgroundColor: AppColors.mist,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          Text(
            'How often the sensor sends a reading.\n'
            'Water level setup is on the Setup tab.',
            style: GoogleFonts.manrope(
              color: AppColors.muted,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => context.push('/audit'),
            icon: const Icon(Icons.receipt_long_outlined),
            label: const Text('Activity log'),
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
                    'Display units',
                    style: GoogleFonts.manrope(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Water level and raw level on Level / History.',
                    style: const TextStyle(color: AppColors.muted, height: 1.35),
                  ),
                  const SizedBox(height: 12),
                  const UnitPicker(),
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
                    'Send every…',
                    style: GoogleFonts.manrope(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (displayApplied != null)
                        'Now: ${_friendlySeconds(displayApplied)}',
                      if (displayPending != null &&
                          displayPending != displayApplied)
                        'Next: ${_friendlySeconds(displayPending)}',
                      if (displayApplied == null && displayPending == null)
                        'Join sensor WiFi, then choose a time (10 sec – 1 hour).',
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
                            backgroundColor: selectedSeconds == p.$2
                                ? AppColors.deepTeal.withValues(alpha: 0.12)
                                : null,
                            side: BorderSide(
                              color: selectedSeconds == p.$2
                                  ? AppColors.deepTeal
                                  : AppColors.line,
                              width: selectedSeconds == p.$2 ? 2 : 1,
                            ),
                          ),
                          onPressed: _savingInterval
                              ? null
                              : () => _applyInterval(p.$2),
                          child: Text(p.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Or type a value',
                    style: GoogleFonts.manrope(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<_IntervalUnit>(
                    segments: const [
                      ButtonSegment(
                        value: _IntervalUnit.seconds,
                        label: Text('Seconds'),
                      ),
                      ButtonSegment(
                        value: _IntervalUnit.minutes,
                        label: Text('Minutes'),
                      ),
                      ButtonSegment(
                        value: _IntervalUnit.hours,
                        label: Text('Hours'),
                      ),
                    ],
                    selected: {_unit},
                    onSelectionChanged: (s) {
                      setState(() => _unit = s.first);
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _valueController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: switch (_unit) {
                              _IntervalUnit.seconds => 'Seconds',
                              _IntervalUnit.minutes => 'Minutes',
                              _IntervalUnit.hours => 'Hours',
                            },
                            hintText: switch (_unit) {
                              _IntervalUnit.seconds => '30',
                              _IntervalUnit.minutes => '5',
                              _IntervalUnit.hours => '1',
                            },
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _savingInterval
                            ? null
                            : () {
                                final sec = _secondsFromField();
                                if (sec == null || sec < 10 || sec > 3600) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Use a time between 10 seconds and 1 hour',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                _applyInterval(sec);
                              },
                        child: _savingInterval
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
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
                    'Connect to sensor',
                    style: GoogleFonts.manrope(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'WiFi name ${AppConstants.gatewaySsid} · password ${AppConstants.gatewayPassword}',
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
                            final wifi = await net.ensureWifiEnabled();
                            if (wifi == 'prompt') {
                              if (!mounted) return;
                              setState(() {
                                _busy = false;
                                _note =
                                    'WiFi is off. Turn it on, then try again.';
                              });
                              return;
                            }
                            if (wifi == 'enabling') {
                              await Future<void>.delayed(
                                const Duration(seconds: 2),
                              );
                            }
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
                      _busy ? 'Connecting…' : 'Connect to sensor WiFi',
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
