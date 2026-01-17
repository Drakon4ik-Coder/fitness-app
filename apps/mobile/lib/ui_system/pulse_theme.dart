import 'package:flutter/material.dart';

import 'tokens.dart';

class PulseColors {
  static const Color background = Color(0xFF0B0F14);
  static const Color surface = Color(0xFF0F1621);
  static const Color surfaceLow = Color(0xFF121A26);
  static const Color surfaceContainer = Color(0xFF162031);
  static const Color surfaceHigh = Color(0xFF1C2738);
  static const Color surfaceHighest = Color(0xFF243146);
  static const Color surfaceVariant = Color(0xFF1B2433);
  static const Color outline = Color(0xFF2B374B);
  static const Color outlineVariant = Color(0xFF1F2A3B);
  static const Color onSurface = Color(0xFFEAF1F7);
  static const Color onSurfaceVariant = Color(0xFFB3C0D2);

  static const Color neonGreen = Color(0xFF7CFF6B);
  static const Color neonGreenOn = Color(0xFF0B1F12);
  static const Color neonGreenContainer = Color(0xFF173421);
  static const Color neonGreenContainerOn = Color(0xFFB7FFA6);

  static const Color neonCyan = Color(0xFF4CD7FF);
  static const Color neonCyanOn = Color(0xFF06202B);
  static const Color neonCyanContainer = Color(0xFF0F2F3B);
  static const Color neonCyanContainerOn = Color(0xFFA3EEFF);

  static const Color neonAmber = Color(0xFFFFC857);
  static const Color neonAmberOn = Color(0xFF2A1A00);
  static const Color neonAmberContainer = Color(0xFF3A2B05);
  static const Color neonAmberContainerOn = Color(0xFFFFE2A6);

  static const Color error = Color(0xFFFF6B6B);
  static const Color onError = Color(0xFF2A0505);
  static const Color errorContainer = Color(0xFF3A0F0F);
  static const Color onErrorContainer = Color(0xFFFFB3B3);

  static const Color ringTrack = Color(0xFF243247);

  static const Color macroProtein = neonGreen;
  static const Color macroCarbs = neonCyan;
  static const Color macroFat = neonAmber;
}

@immutable
class PulseEffects extends ThemeExtension<PulseEffects> {
  const PulseEffects({
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

  static const PulseEffects fallback = PulseEffects(
    glowLow: 6,
    glowMedium: 12,
    glowHigh: 20,
    glassOverlayOpacity: 0.12,
    blurRadius: 16,
    ringTrackColor: PulseColors.ringTrack,
  );

  @override
  PulseEffects copyWith({
    double? glowLow,
    double? glowMedium,
    double? glowHigh,
    double? glassOverlayOpacity,
    double? blurRadius,
    Color? ringTrackColor,
  }) {
    return PulseEffects(
      glowLow: glowLow ?? this.glowLow,
      glowMedium: glowMedium ?? this.glowMedium,
      glowHigh: glowHigh ?? this.glowHigh,
      glassOverlayOpacity: glassOverlayOpacity ?? this.glassOverlayOpacity,
      blurRadius: blurRadius ?? this.blurRadius,
      ringTrackColor: ringTrackColor ?? this.ringTrackColor,
    );
  }

  @override
  PulseEffects lerp(ThemeExtension<PulseEffects>? other, double t) {
    if (other is! PulseEffects) {
      return this;
    }
    return PulseEffects(
      glowLow: lerpDouble(glowLow, other.glowLow, t),
      glowMedium: lerpDouble(glowMedium, other.glowMedium, t),
      glowHigh: lerpDouble(glowHigh, other.glowHigh, t),
      glassOverlayOpacity:
          lerpDouble(glassOverlayOpacity, other.glassOverlayOpacity, t),
      blurRadius: lerpDouble(blurRadius, other.blurRadius, t),
      ringTrackColor: Color.lerp(ringTrackColor, other.ringTrackColor, t) ??
          ringTrackColor,
    );
  }

  double lerpDouble(double a, double b, double t) {
    return a + (b - a) * t;
  }
}

class PulseTheme {
  static ThemeData dark() {
    final base = ColorScheme.fromSeed(
      seedColor: PulseColors.neonGreen,
      brightness: Brightness.dark,
    );
    final scheme = base.copyWith(
      primary: PulseColors.neonGreen,
      onPrimary: PulseColors.neonGreenOn,
      primaryContainer: PulseColors.neonGreenContainer,
      onPrimaryContainer: PulseColors.neonGreenContainerOn,
      secondary: PulseColors.neonCyan,
      onSecondary: PulseColors.neonCyanOn,
      secondaryContainer: PulseColors.neonCyanContainer,
      onSecondaryContainer: PulseColors.neonCyanContainerOn,
      tertiary: PulseColors.neonAmber,
      onTertiary: PulseColors.neonAmberOn,
      tertiaryContainer: PulseColors.neonAmberContainer,
      onTertiaryContainer: PulseColors.neonAmberContainerOn,
      error: PulseColors.error,
      onError: PulseColors.onError,
      errorContainer: PulseColors.errorContainer,
      onErrorContainer: PulseColors.onErrorContainer,
      background: PulseColors.background,
      onBackground: PulseColors.onSurface,
      surface: PulseColors.surface,
      onSurface: PulseColors.onSurface,
      surfaceVariant: PulseColors.surfaceVariant,
      onSurfaceVariant: PulseColors.onSurfaceVariant,
      outline: PulseColors.outline,
      outlineVariant: PulseColors.outlineVariant,
      surfaceTint: PulseColors.neonGreen,
      surfaceContainerLowest: PulseColors.surface,
      surfaceContainerLow: PulseColors.surfaceLow,
      surfaceContainer: PulseColors.surfaceContainer,
      surfaceContainerHigh: PulseColors.surfaceHigh,
      surfaceContainerHighest: PulseColors.surfaceHighest,
    );

    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: BorderSide(color: scheme.outline),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.background,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
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
        color: scheme.surfaceContainer,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.card,
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
      ),
      extensions: const [
        PulseEffects(
          glowLow: 6,
          glowMedium: 12,
          glowHigh: 20,
          glassOverlayOpacity: 0.12,
          blurRadius: 16,
          ringTrackColor: PulseColors.ringTrack,
        ),
      ],
    );
  }

  static PulseEffects effectsOf(BuildContext context) {
    return Theme.of(context).extension<PulseEffects>() ??
        PulseEffects.fallback;
  }
}
