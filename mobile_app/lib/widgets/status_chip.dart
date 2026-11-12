import 'package:flutter/material.dart';

import '../app/theme.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    this.ok = true,
    this.warn = false,
  });

  final String label;
  final bool ok;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final color = warn
        ? AppColors.warn
        : ok
            ? AppColors.deepTeal
            : AppColors.danger;
    final bg = warn
        ? AppColors.warnBg
        : ok
            ? AppColors.okBg
            : AppColors.dangerBg;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}
