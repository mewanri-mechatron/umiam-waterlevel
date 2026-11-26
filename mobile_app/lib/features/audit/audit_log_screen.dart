import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../services/audit_log_service.dart';
import '../../services/firebase_service.dart';

class AuditLogScreen extends ConsumerStatefulWidget {
  const AuditLogScreen({super.key});

  @override
  ConsumerState<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends ConsumerState<AuditLogScreen> {
  /// 0 = this phone's local log, 1 = logs from any phone in the cloud.
  int _tab = 0;

  List<CloudPhoneInfo> _phones = const [];
  String? _selectedPhoneId;
  List<CloudLogEntry> _cloudLogs = const [];
  bool _loadingCloud = false;
  String? _cloudError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(auditLogServiceProvider).ensureLoaded();
    });
  }

  Future<void> _loadCloudPhones() async {
    setState(() {
      _loadingCloud = true;
      _cloudError = null;
    });
    try {
      final firebase = ref.read(firebaseServiceProvider);
      await firebase.initialize();
      final phones = await firebase.fetchDevices();
      if (!mounted) return;
      setState(() {
        _phones = phones;
        _selectedPhoneId ??= phones.isEmpty ? null : phones.first.deviceId;
      });
      if (_selectedPhoneId != null) {
        await _loadCloudLogs(_selectedPhoneId!);
      } else {
        setState(() {
          _cloudLogs = const [];
          _loadingCloud = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cloudError = 'Could not load phones. Check mobile data.\n$e';
        _loadingCloud = false;
      });
    }
  }

  Future<void> _loadCloudLogs(String deviceId) async {
    setState(() {
      _loadingCloud = true;
      _cloudError = null;
      _selectedPhoneId = deviceId;
    });
    try {
      final logs = await ref
          .read(firebaseServiceProvider)
          .fetchDeviceLogs(deviceId);
      if (!mounted) return;
      setState(() {
        _cloudLogs = logs;
        _loadingCloud = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cloudError = 'Could not load logs.\n$e';
        _loadingCloud = false;
      });
    }
  }

  Future<void> _copyLines(List<String> lines) async {
    await Clipboard.setData(
      ClipboardData(text: lines.isEmpty ? '(empty)' : lines.join('\n')),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied')));
  }

  @override
  Widget build(BuildContext context) {
    final audit = ref.watch(auditLogServiceProvider);

    return Scaffold(
      backgroundColor: AppColors.mist,
      appBar: AppBar(
        title: const Text('Activity log'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              if (_tab == 0) {
                audit.refresh();
              } else {
                unawaitedLoad();
              }
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (_tab == 0) ...[
            IconButton(
              tooltip: 'Copy all',
              onPressed: () {
                final text = audit.entries.map(_formatLocal).toList();
                _copyLines(text);
              },
              icon: const Icon(Icons.copy_all_outlined),
            ),
            IconButton(
              tooltip: 'Clear',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear this phone’s log?'),
                    content: const Text(
                      'Clears the log saved on this phone only. '
                      'Copies already sent to the cloud stay there.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                );
                if (ok == true) await audit.clear();
              },
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ] else
            IconButton(
              tooltip: 'Copy',
              onPressed: () =>
                  _copyLines(_cloudLogs.map(_formatCloud).toList()),
              icon: const Icon(Icons.copy_all_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('This phone')),
                ButtonSegment(value: 1, label: Text('All phones')),
              ],
              selected: {_tab},
              onSelectionChanged: (s) {
                final next = s.first;
                setState(() => _tab = next);
                if (next == 1 && _phones.isEmpty && !_loadingCloud) {
                  unawaitedLoad();
                }
              },
            ),
          ),
          Expanded(
            child: _tab == 0
                ? _LocalLogList(audit: audit)
                : _CloudLogPanel(
                    phones: _phones,
                    selectedId: _selectedPhoneId,
                    logs: _cloudLogs,
                    loading: _loadingCloud,
                    error: _cloudError,
                    onSelect: _loadCloudLogs,
                    onRetry: unawaitedLoad,
                  ),
          ),
        ],
      ),
    );
  }

  void unawaitedLoad() {
    _loadCloudPhones();
  }

  static String _formatLocal(AuditEntry e) {
    final ts = DateFormat('yyyy-MM-dd h:mm:ss a').format(e.createdAt);
    final detail = e.detail == null || e.detail!.isEmpty
        ? ''
        : '\n  ${e.detail}';
    return '[$ts] ${e.level.toUpperCase()} ${e.category}: ${e.message}$detail';
  }

  static String _formatCloud(CloudLogEntry e) {
    final ts = DateFormat(
      'yyyy-MM-dd h:mm:ss a',
    ).format(DateTime.fromMillisecondsSinceEpoch(e.createdAtMs));
    final detail = e.detail == null || e.detail!.isEmpty
        ? ''
        : '\n  ${e.detail}';
    return '[$ts] ${e.level.toUpperCase()} ${e.category}: ${e.message}$detail';
  }
}

class _LocalLogList extends StatelessWidget {
  const _LocalLogList({required this.audit});
  final AuditLogService audit;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: audit,
      builder: (context, _) {
        final entries = audit.entries;
        if (entries.isEmpty) {
          return Center(
            child: Text(
              'No events yet.',
              style: GoogleFonts.poppins(color: AppColors.muted),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          itemCount: entries.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) => _AuditTile(
            level: entries[i].level,
            category: entries[i].category,
            message: entries[i].message,
            detail: entries[i].detail,
            when: entries[i].createdAt,
          ),
        );
      },
    );
  }
}

String _phoneSubtitle(List<CloudPhoneInfo> phones, String id) {
  CloudPhoneInfo? match;
  for (final p in phones) {
    if (p.deviceId == id) {
      match = p;
      break;
    }
  }
  if (match == null) return id;
  final seen = match.lastSeenMs <= 0
      ? '—'
      : DateFormat(
          'd MMM, h:mm a',
        ).format(DateTime.fromMillisecondsSinceEpoch(match.lastSeenMs));
  return '${match.model} · app ${match.appVersion} · last report $seen'
      '${match.readingsWaiting > 0 ? ' · ${match.readingsWaiting} waiting' : ''}';
}

class _CloudLogPanel extends StatelessWidget {
  const _CloudLogPanel({
    required this.phones,
    required this.selectedId,
    required this.logs,
    required this.loading,
    required this.error,
    required this.onSelect,
    required this.onRetry,
  });

  final List<CloudPhoneInfo> phones;
  final String? selectedId;
  final List<CloudLogEntry> logs;
  final bool loading;
  final String? error;
  final ValueChanged<String> onSelect;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'Logs each phone sent to the cloud. Needs mobile data.',
            style: GoogleFonts.poppins(
              fontSize: 12,
              color: AppColors.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (phones.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: DropdownButtonFormField<String>(
              initialValue: selectedId,
              decoration: InputDecoration(
                labelText: 'Phone',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              items: [
                for (final p in phones)
                  DropdownMenuItem(
                    value: p.deviceId,
                    child: Text(
                      '${p.name} · ${p.deviceId}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: loading
                  ? null
                  : (id) {
                      if (id != null) onSelect(id);
                    },
            ),
          ),
        if (selectedId != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              _phoneSubtitle(phones, selectedId!),
              style: GoogleFonts.poppins(
                fontSize: 11.5,
                color: AppColors.muted,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          error!,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(
                            color: AppColors.danger,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: onRetry,
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                )
              : phones.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No phones have reported yet.\n'
                      'Open the app on a phone with mobile data.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.poppins(color: AppColors.muted),
                    ),
                  ),
                )
              : logs.isEmpty
              ? Center(
                  child: Text(
                    'No cloud logs for this phone yet.',
                    style: GoogleFonts.poppins(color: AppColors.muted),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                  itemCount: logs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final e = logs[i];
                    return _AuditTile(
                      level: e.level,
                      category: e.category,
                      message: e.message,
                      detail: e.detail,
                      when: DateTime.fromMillisecondsSinceEpoch(e.createdAtMs),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _AuditTile extends StatelessWidget {
  const _AuditTile({
    required this.level,
    required this.category,
    required this.message,
    required this.when,
    this.detail,
  });

  final String level;
  final String category;
  final String message;
  final String? detail;
  final DateTime when;

  @override
  Widget build(BuildContext context) {
    final color = switch (level) {
      'error' => AppColors.danger,
      'warn' => AppColors.warn,
      _ => AppColors.deepTeal,
    };
    final bg = switch (level) {
      'error' => AppColors.dangerBg,
      'warn' => AppColors.warnBg,
      _ => AppColors.panelSoft,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  level.toUpperCase(),
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                category,
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.muted,
                ),
              ),
              const Spacer(),
              Text(
                DateFormat('d MMM, h:mm:ss a').format(when),
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  color: AppColors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              height: 1.35,
            ),
          ),
          if (detail != null && detail!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              detail!,
              style: GoogleFonts.poppins(
                fontSize: 11.5,
                color: AppColors.muted,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
