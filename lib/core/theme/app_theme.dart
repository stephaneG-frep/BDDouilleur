import 'package:flutter/material.dart';

/// Palette du Laboratoire du BDDouilleur.
abstract final class BddColors {
  static const nuit = Color(0xFF10172A);
  static const violet = Color(0xFF8358FF);
  static const turquoise = Color(0xFF20D6C7);
  static const orange = Color(0xFFFFAA55);
  static const rose = Color(0xFFFF648B);
  static const vert = Color(0xFF44D7A8);

  static const nuitClair = Color(0xFF1B2440);
  static const nuitCarte = Color(0xFF222C4D);
  static const lavande = Color(0xFFF4F1FF);
}

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final base = ColorScheme.fromSeed(seedColor: BddColors.violet, brightness: brightness);
    final scheme = base.copyWith(
      primary: dark ? const Color(0xFFA68BFF) : BddColors.violet,
      onPrimary: dark ? BddColors.nuit : Colors.white,
      secondary: dark ? BddColors.turquoise : const Color(0xFF0E8F86),
      onSecondary: dark ? BddColors.nuit : Colors.white,
      tertiary: dark ? BddColors.orange : const Color(0xFFB4610C),
      error: dark ? BddColors.rose : const Color(0xFFC6284F),
      surface: dark ? BddColors.nuit : const Color(0xFFFBFAFF),
      onSurface: dark ? const Color(0xFFE8EAF6) : BddColors.nuit,
      surfaceContainerLowest: dark ? const Color(0xFF0B1120) : Colors.white,
      surfaceContainerLow: dark ? BddColors.nuitClair : BddColors.lavande,
      surfaceContainer: dark ? BddColors.nuitCarte : const Color(0xFFEDE8FF),
      surfaceContainerHigh: dark ? const Color(0xFF2A355C) : const Color(0xFFE6E0FA),
      surfaceContainerHighest: dark ? const Color(0xFF33406B) : const Color(0xFFDDD5F5),
    );

    final radius = BorderRadius.circular(18);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 2,
        titleTextStyle: (dark ? Typography.material2021().white : Typography.material2021().black)
            .titleLarge!
            .copyWith(fontSize: 20, fontWeight: FontWeight.w700, color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: radius),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: radius)),
      chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.primary.withValues(alpha: 0.22),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.primary.withValues(alpha: 0.22),
      ),
    );
  }

  static const mono = TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4);
}
