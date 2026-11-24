import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../app/theme.dart';

/// Legacy route — calibration and raw levels live on Setup / History / Level.
class ReadingsScreen extends StatelessWidget {
  const ReadingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.mist,
      appBar: AppBar(title: const Text('Readings')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Use the Level, History, and Setup tabs.\n'
            'Set the actual water level on Setup.\n'
            'History shows water level and raw level (pick units on Level / History).',
            textAlign: TextAlign.center,
            style: GoogleFonts.manrope(
              height: 1.45,
              fontWeight: FontWeight.w600,
              color: AppColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}
