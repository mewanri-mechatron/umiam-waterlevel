import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const deepTeal = Color(0xFF0A5C4B);
  static const teal = Color(0xFF0F7A63);
  static const mist = Color(0xFFF0F5F4);
  static const surface = Color(0xFFFFFFFF);
  static const ink = Color(0xFF14201C);
  static const muted = Color(0xFF5C6F68);
  static const line = Color(0xFFD5E0DB);
  static const warn = Color(0xFF8A5A00);
  static const warnBg = Color(0xFFFFF4D6);
  static const danger = Color(0xFFA11D2E);
  static const dangerBg = Color(0xFFFCE8EB);
  static const okBg = Color(0xFFD9F2EA);
}

ThemeData buildAppTheme() {
  final base = ColorScheme.fromSeed(
    seedColor: AppColors.deepTeal,
    brightness: Brightness.light,
    primary: AppColors.deepTeal,
    surface: AppColors.surface,
  );

  final textTheme = GoogleFonts.manropeTextTheme().apply(
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
      titleTextStyle: GoogleFonts.manrope(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
        letterSpacing: -0.3,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: AppColors.surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.deepTeal,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: GoogleFonts.manrope(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.deepTeal,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        side: const BorderSide(color: AppColors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: GoogleFonts.manrope(fontWeight: FontWeight.w600),
      ),
    ),
  );
}
