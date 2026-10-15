import 'package:flutter/material.dart';

/// Brand palette shared with the website: safelight amber on darkroom ink.
class Brand {
  static const amber = Color(0xFFFFA24A);
  static const amberDeep = Color(0xFFB4530B);
  static const safelight = Color(0xFFE8452C);
  static const ink = Color(0xFF100D0A);
  static const ink2 = Color(0xFF19140F);
  static const ink3 = Color(0xFF241C15);
  static const line = Color(0xFF3A2E23);
  static const paper = Color(0xFFF2E8D8);
  static const paperDim = Color(0xFFC9BBA5);
  static const online = Color(0xFF6FCF7C);
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = dark
      ? ColorScheme.fromSeed(seedColor: Brand.amber, brightness: Brightness.dark).copyWith(
          primary: Brand.amber,
          onPrimary: Brand.ink,
          secondary: Brand.safelight,
          surface: Brand.ink,
          onSurface: Brand.paper,
          onSurfaceVariant: Brand.paperDim,
          surfaceContainerLowest: const Color(0xFF0B0907),
          surfaceContainerLow: Brand.ink2,
          surfaceContainer: Brand.ink2,
          surfaceContainerHigh: Brand.ink3,
          surfaceContainerHighest: const Color(0xFF2E241B),
          outline: const Color(0xFF6B5A49),
          outlineVariant: Brand.line,
          error: const Color(0xFFFF8A73),
        )
      : ColorScheme.fromSeed(seedColor: Brand.amber).copyWith(
          primary: Brand.amberDeep,
          onPrimary: Colors.white,
          secondary: Brand.safelight,
          surface: const Color(0xFFFBF6EE),
          surfaceContainerLow: const Color(0xFFF5EDE1),
          surfaceContainer: const Color(0xFFF1E7D9),
          surfaceContainerHigh: const Color(0xFFEBDFCD),
        );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);
  final text = base.textTheme.apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: text.copyWith(
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      labelSmall: text.labelSmall?.copyWith(letterSpacing: 1.1, fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primary.withValues(alpha: dark ? 0.22 : 0.16),
      surfaceTintColor: Colors.transparent,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primary.withValues(alpha: dark ? 0.22 : 0.16),
      selectedIconTheme: IconThemeData(color: scheme.primary),
      selectedLabelTextStyle: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
  );
}
