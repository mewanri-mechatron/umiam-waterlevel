import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../core/utils/display_units.dart';

/// Segmented unit control matching the web dashboard.
class UnitPicker extends ConsumerWidget {
  const UnitPicker({super.key, this.dense = false});

  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unit = ref.watch(displayLengthUnitProvider);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.panelSoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final u in DisplayLengthUnit.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Material(
                color: unit == u ? AppColors.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () =>
                      ref.read(displayLengthUnitProvider.notifier).setUnit(u),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: dense ? 10 : 12,
                      vertical: dense ? 6 : 8,
                    ),
                    child: Text(
                      u.label,
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w600,
                        fontSize: dense ? 12 : 13,
                        color: unit == u ? AppColors.deepTeal : AppColors.muted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
