import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../services/audit_log_service.dart';

class AuditLogScreen extends ConsumerStatefulWidget {
  const AuditLogScreen({super.key});

  @override
  ConsumerState<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends ConsumerState<AuditLogScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(auditLogServiceProvider).ensureLoaded();
    });
  }

  @override
  Widget build(BuildContext context) {
    final audit = ref.watch(auditLogServiceProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF3F7F5),
      appBar: AppBar(
        title: const Text('Activity log'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => audit.refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Copy all',
            onPressed: () async {
              final text = audit.entries
                  .map((e) {
                    final ts = DateFormat('yyyy-MM-dd h:mm:ss a').format(e.createdAt);
                    final detail = e.detail == null || e.detail!.isEmpty
                        ? ''
                        : '\n  ${e.detail}';
                    return '[$ts] ${e.level.toUpperCase()} ${e.category}: ${e.message}$detail';
                  })
                  .join('\n');
              await Clipboard.setData(ClipboardData(text: text.isEmpty ? '(empty)' : text));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied audit log')),
                );
              }
            },
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Clear audit log?'),
                  content: const Text(
                    'Clears the log on this phone only. Cloud audit copies (if any) stay in Firebase.',
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
        ],
      ),
      body: AnimatedBuilder(
        animation: audit,
        builder: (context, _) {
          final entries = audit.entries;
          if (entries.isEmpty) {
            return Center(
              child: Text(
                'No events yet.\nRun Sync now — logs save to the phone DB and to Firebase when online.',
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(color: AppColors.muted, height: 1.4),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _AuditTile(entry: entries[i]),
          );
        },
      ),
    );
  }
}

class _AuditTile extends StatelessWidget {
  const _AuditTile({required this.entry});

  final AuditEntry entry;

  String get _statusLabel {
    final m = entry.message.toUpperCase();
    if (m.contains('FAILED') || entry.level == 'error') return 'FAILED';
    if (m.contains('PENDING') || entry.level == 'warn') return 'PENDING';
    if (m.contains('SUCCESS') || m.contains('OK')) return 'SUCCESS';
    return entry.level.toUpperCase();
  }

  Color get _accent {
    switch (_statusLabel) {
      case 'FAILED':
        return AppColors.danger;
      case 'PENDING':
        return AppColors.warn;
      case 'SUCCESS':
        return AppColors.deepTeal;
      default:
        switch (entry.level) {
          case 'error':
            return AppColors.danger;
          case 'warn':
            return AppColors.warn;
          default:
            return AppColors.deepTeal;
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ts = DateFormat('dd MMM yyyy h:mm:ss a').format(entry.createdAt);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _statusLabel,
                  style: GoogleFonts.manrope(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: _accent,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                entry.category,
                style: GoogleFonts.manrope(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.muted,
                ),
              ),
              const Spacer(),
              Text(
                ts,
                style: GoogleFonts.manrope(
                  fontSize: 12,
                  color: AppColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            entry.message,
            style: GoogleFonts.manrope(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              height: 1.3,
            ),
          ),
          if (entry.detail != null && entry.detail!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              entry.detail!,
              style: GoogleFonts.manrope(
                fontSize: 12,
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
