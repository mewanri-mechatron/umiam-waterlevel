import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Matches web_dashboard CSS tokens (Poppins + teal surface).
class AppColors {
  static const deepTeal = Color(0xFF004237);
  static const teal = Color(0xFF185A4D);
  static const tealSoft = Color(0xFF91CFBE);
  static const mist = Color(0xFFF8FAF7);
  static const surface = Color(0xFFFFFFFF);
  static const panelSoft = Color(0xFFF2F4F2);
  static const ink = Color(0xFF191C1B);
  static const muted = Color(0xFF3F4946);
  static const outline = Color(0xFFBFC9C4);
  static const line = Color(0xFFE1E3E1);
  static const warn = Color(0xFFB45309);
  static const warnBg = Color(0xFFFEF3C7);
  static const danger = Color(0xFFA11D2E);
  static const dangerBg = Color(0xFFFCE8EB);
  static const ok = Color(0xFF15803D);
  static const okBg = Color(0xFFDCFCE7);
  static const okInk = Color(0xFF14532D);
}

ThemeData buildAppTheme() {
  final base = ColorScheme.fromSeed(
    seedColor: AppColors.deepTeal,
    brightness: Brightness.light,
    primary: AppColors.deepTeal,
    surface: AppColors.surface,
  );

  final textTheme = GoogleFonts.poppinsTextTheme().apply(
    bodyColor: AppColors.ink,
    displayColor: AppColors.ink,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: base,
    scaffoldBackgroundColor: AppColors.mist,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.mist,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.poppins(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
        letterSpacing: -0.3,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: AppColors.surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.outline),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.deepTeal,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.deepTeal,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        side: const BorderSide(color: AppColors.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.okBg,
      labelTextStyle: WidgetStatePropertyAll(
        GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
  );
}
