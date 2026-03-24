import 'package:flutter/material.dart';

import 'tokens.dart';

class LuminaHealthColors {
  static const Color background = Color(0xFF0E0E0E);
  static const Color error = Color(0xFFFF7351);
  static const Color errorContainer = Color(0xFFB92902);
  static const Color onError = Color(0xFF450900);
  static const Color onErrorContainer = Color(0xFFFFD2C8);
  static const Color primary = Color(0xFF6BFF8F);
  static const Color primaryContainer = Color(0xFF0ABC56);
  static const Color onPrimary = Color(0xFF005F28);
  static const Color onPrimaryContainer = Color(0xFF002C0F);
  static const Color secondary = Color(0xFFC180FF);
  static const Color secondaryContainer = Color(0xFF6F00BE);
  static const Color onSecondary = Color(0xFF33005B);
  static const Color onSecondaryContainer = Color(0xFFE9CDFF);
  static const Color tertiary = Color(0xFFFF8439);
  static const Color tertiaryContainer = Color(0xFFF77113);
  static const Color surface = Color(0xFF0E0E0E);
  static const Color surfaceBright = Color(0xFF2C2C2C);
  static const Color surfaceContainer = Color(0xFF1A1A1A);
  static const Color surfaceContainerHigh = Color(0xFF20201F);
  static const Color surfaceContainerHighest = Color(0xFF262626);
  static const Color surfaceContainerLow = Color(0xFF131313);
  static const Color surfaceContainerLowest = Color(0xFF000000);
  static const Color surfaceVariant = Color(0xFF262626);
  static const Color onSurface = Color(0xFFFFFFFF);
  static const Color onSurfaceVariant = Color(0xFFADAAAA);
  static const Color outline = Color(0xFF767575);
  static const Color outlineVariant = Color(0xFF484847);
}

@immutable
class LuminaHealthEffects extends ThemeExtension<LuminaHealthEffects> {
  const LuminaHealthEffects({
    required this.glowLow,
    required this.glowMedium,
    required this.glowHigh,
    required this.glassOverlayOpacity,
    required this.blurRadius,
    required this.ringTrackColor,
  });

  final double glowLow;
  final double glowMedium;
  final double glowHigh;
  final double glassOverlayOpacity;
  final double blurRadius;
  final Color ringTrackColor;

  static const LuminaHealthEffects fallback = LuminaHealthEffects(
    glowLow: 6,
    glowMedium: 12,
    glowHigh: 20,
    glassOverlayOpacity: 0.12,
    blurRadius: 16,
    ringTrackColor: LuminaHealthColors.surfaceContainerHigh,
  );

  @override
  LuminaHealthEffects copyWith({
    double? glowLow,
    double? glowMedium,
    double? glowHigh,
    double? glassOverlayOpacity,
    double? blurRadius,
    Color? ringTrackColor,
  }) {
    return LuminaHealthEffects(
      glowLow: glowLow ?? this.glowLow,
      glowMedium: glowMedium ?? this.glowMedium,
      glowHigh: glowHigh ?? this.glowHigh,
      glassOverlayOpacity: glassOverlayOpacity ?? this.glassOverlayOpacity,
      blurRadius: blurRadius ?? this.blurRadius,
      ringTrackColor: ringTrackColor ?? this.ringTrackColor,
    );
  }

  @override
  LuminaHealthEffects lerp(ThemeExtension<LuminaHealthEffects>? other, double t) {
    if (other is! LuminaHealthEffects) {
      return this;
    }
    return LuminaHealthEffects(
      glowLow: lerpDouble(glowLow, other.glowLow, t),
      glowMedium: lerpDouble(glowMedium, other.glowMedium, t),
      glowHigh: lerpDouble(glowHigh, other.glowHigh, t),
      glassOverlayOpacity: lerpDouble(glassOverlayOpacity, other.glassOverlayOpacity, t),
      blurRadius: lerpDouble(blurRadius, other.blurRadius, t),
      ringTrackColor: Color.lerp(ringTrackColor, other.ringTrackColor, t) ?? ringTrackColor,
    );
  }

  double lerpDouble(double a, double b, double t) {
    return a + (b - a) * t;
  }
}

class LuminaHealthTheme {
  static ThemeData dark() {
    final base = ColorScheme.fromSeed(
      seedColor: LuminaHealthColors.primary,
      brightness: Brightness.dark,
    );
    final scheme = base.copyWith(
      primary: LuminaHealthColors.primary,
      onPrimary: LuminaHealthColors.onPrimary,
      primaryContainer: LuminaHealthColors.primaryContainer,
      onPrimaryContainer: LuminaHealthColors.onPrimaryContainer,
      secondary: LuminaHealthColors.secondary,
      onSecondary: LuminaHealthColors.onSecondary,
      secondaryContainer: LuminaHealthColors.secondaryContainer,
      onSecondaryContainer: LuminaHealthColors.onSecondaryContainer,
      tertiary: LuminaHealthColors.tertiary,
      onTertiary: Color(0xFF471A00),
      tertiaryContainer: LuminaHealthColors.tertiaryContainer,
      onTertiaryContainer: Color(0xFF321000),
      error: LuminaHealthColors.error,
      onError: LuminaHealthColors.onError,
      errorContainer: LuminaHealthColors.errorContainer,
      onErrorContainer: LuminaHealthColors.onErrorContainer,
      surface: LuminaHealthColors.surface,
      onSurface: LuminaHealthColors.onSurface,
      onSurfaceVariant: LuminaHealthColors.onSurfaceVariant,
      outline: LuminaHealthColors.outline,
      outlineVariant: LuminaHealthColors.outlineVariant,
      surfaceTint: LuminaHealthColors.primary,
      surfaceContainerLowest: LuminaHealthColors.surfaceContainerLowest,
      surfaceContainerLow: LuminaHealthColors.surfaceContainerLow,
      surfaceContainer: LuminaHealthColors.surfaceContainer,
      surfaceContainerHigh: LuminaHealthColors.surfaceContainerHigh,
      surfaceContainerHighest: LuminaHealthColors.surfaceContainerHighest,
    );

    // The Design.md specifically requests: Input style with surface-container-highest and rounded-md corner
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: const BorderSide(color: Colors.transparent),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: const BorderSide(color: Colors.transparent),
        ),
        errorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.error, width: 1.5),
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
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
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
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        thickness: 1,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card.topLeft.x),
          side: BorderSide.none, // "Lines are a failure of hierarchy"
        ),
      ),
      extensions: const [LuminaHealthEffects.fallback],
    );
  }

  static LuminaHealthEffects effectsOf(BuildContext context) {
    return Theme.of(context).extension<LuminaHealthEffects>() ??
        LuminaHealthEffects.fallback;
  }
}
