import 'package:flutter/material.dart';

import 'tokens.dart';

class AppTheme {
  static ThemeData light() => _buildTheme(Brightness.light);

  static ThemeData dark() => _buildTheme(Brightness.dark);

  static ThemeData _buildTheme(Brightness brightness) {
    const seedColor = Color(0xFF2E7D32);
    const warmSurface = Color(0xFFF6F1EB);
    const warmSurfaceVariant = Color(0xFFECE3D9);
    const darkSurface = Color(0xFF1D1B18);
    const darkSurfaceVariant = Color(0xFF2B2722);

    final base = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );
    final surface = brightness == Brightness.light ? warmSurface : darkSurface;
    final surfaceContainerHighest =
        brightness == Brightness.light ? warmSurfaceVariant : darkSurfaceVariant;
    final surfaceContainerLow =
        Color.lerp(surface, surfaceContainerHighest, 0.24)!;
    final surfaceContainer =
        Color.lerp(surface, surfaceContainerHighest, 0.48)!;
    final surfaceContainerHigh =
        Color.lerp(surface, surfaceContainerHighest, 0.72)!;
    final colorScheme = base.copyWith(
      surface: surface,
      surfaceContainerLowest: surface,
      surfaceContainerLow: surfaceContainerLow,
      surfaceContainer: surfaceContainer,
      surfaceContainerHigh: surfaceContainerHigh,
      surfaceContainerHighest: surfaceContainerHighest,
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
      cardTheme: CardThemeData(
        elevation: 0,
        color: colorScheme.surfaceContainer,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.card,
          side: BorderSide(
            color: colorScheme.outlineVariant.withOpacity(0.6),
          ),
        ),
      ),
    );
  }
}
