import 'package:flutter/material.dart';

import 'tokens.dart';

class AppTheme {
  static ThemeData light() => _buildTheme(Brightness.light);

  static ThemeData dark() => _buildTheme(Brightness.dark);

  static ThemeData _buildTheme(Brightness brightness) {
    const seedColor = Color(0xFF2E7D32);
    const warmSurface = Color(0xFFF7F2EC);
    const warmSurfaceVariant = Color(0xFFE9DED1);
    const warmOutline = Color(0xFFD2C6B8);
    const warmOutlineVariant = Color(0xFFE0D6CA);
    const darkSurface = Color(0xFF1D1B18);
    const darkSurfaceVariant = Color(0xFF2A2622);
    const darkOutline = Color(0xFF4A433D);
    const darkOutlineVariant = Color(0xFF3A352F);

    final base = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );
    final surface = brightness == Brightness.light ? warmSurface : darkSurface;
    final surfaceContainerHighest =
        brightness == Brightness.light ? warmSurfaceVariant : darkSurfaceVariant;
    final outline = brightness == Brightness.light ? warmOutline : darkOutline;
    final outlineVariant = brightness == Brightness.light
        ? warmOutlineVariant
        : darkOutlineVariant;
    final surfaceContainerLow =
        Color.lerp(surface, surfaceContainerHighest, 0.3)!;
    final surfaceContainer =
        Color.lerp(surface, surfaceContainerHighest, 0.6)!;
    final surfaceContainerHigh =
        Color.lerp(surface, surfaceContainerHighest, 0.8)!;
    final colorScheme = base.copyWith(
      surface: surface,
      surfaceContainerLowest: surface,
      surfaceContainerLow: surfaceContainerLow,
      surfaceContainer: surfaceContainer,
      surfaceContainerHigh: surfaceContainerHigh,
      surfaceContainerHighest: surfaceContainerHighest,
      outline: outline,
      outlineVariant: outlineVariant,
      surfaceTint: surface,
    );
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: BorderSide(color: colorScheme.outline),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surfaceContainerLowest,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        errorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: colorScheme.error),
        ),
        focusedErrorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: colorScheme.error, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant.withValues(alpha: 0.4),
        thickness: 1,
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        color: colorScheme.surfaceContainer,
        margin: EdgeInsets.zero,
        surfaceTintColor: colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.card,
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}
