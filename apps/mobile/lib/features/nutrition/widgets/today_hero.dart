import 'package:flutter/material.dart';
import '../../../ui_components/ui_components.dart';
import '../../../ui_system/lumina_health_theme.dart';
import '../../../ui_system/tokens.dart';

// Today page: calorie ring hero (KAN-124: extracted from
// nutrition_today_page.dart).

/// The hero biometric block: calorie ring (remaining/over + add button) over
/// the kcal stats row. BURNED appears only when [burnedKcal] is non-null,
/// i.e. an activity source is configured (KAN-37); otherwise EATEN sits
/// centered on its own.
class TodayHeroSection extends StatelessWidget {
  const TodayHeroSection({
    super.key,
    required this.ringProgress,
    required this.ringColor,
    required this.kcalOver,
    required this.kcalCenterValue,
    required this.eatenKcal,
    required this.burnedKcal,
    required this.onAddFood,
  });

  final double ringProgress;
  final Color ringColor;
  final bool kcalOver;
  final int kcalCenterValue;
  final int eatenKcal;

  /// Null hides the BURNED stat (no activity source configured).
  final int? burnedKcal;
  final VoidCallback onAddFood;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      children: [
        SizedBox(
          height: 288,
          width: 288,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Decorative: the merged center stat below carries the same
              // information for screen readers (KAN-54).
              ExcludeSemantics(
                child: GlowingProgressRing(
                  progress: ringProgress,
                  size: 288,
                  thickness: 12,
                  trackColor: scheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  progressColor: ringColor,
                  glowColor: ringColor,
                  glowLevel: PulseGlowLevel.high,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // One announcement ("1479 kilocalories left"), not the
                  // disjoint "1479" / "LEFT" fragments the visuals use.
                  // Flexible + FittedBox: at large text scales the figure
                  // shrinks to stay inside the fixed-size ring instead of
                  // overflowing it; the 48dp CTA below never shrinks (KAN-40).
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Semantics(
                        label:
                            '$kcalCenterValue kilocalories '
                            '${kcalOver ? 'over goal' : 'left'}',
                        value:
                            '${(ringProgress.clamp(0.0, 1.0) * 100).round()} '
                            'percent of calorie goal used',
                        excludeSemantics: true,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              kcalOver
                                  ? '+$kcalCenterValue'
                                  : '$kcalCenterValue',
                              style: theme.textTheme.displayLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                                height: 1,
                                color: kcalOver
                                    ? LuminaHealthColors.warning
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              kcalOver ? 'OVER' : 'LEFT',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                letterSpacing: 2.0,
                                color: kcalOver
                                    ? LuminaHealthColors.warning
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // The app's primary CTA: filled, 48dp target, labelled.
                  IconButton(
                    onPressed: onAddFood,
                    tooltip: 'Add food',
                    icon: const Icon(Icons.add),
                    iconSize: 28,
                    style: IconButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      minimumSize: const Size(48, 48),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Row(
          children: [
            Expanded(
              child: _KcalStat(
                label: 'EATEN',
                kcal: eatenKcal,
                color: scheme.primary,
                alignment: burnedKcal == null
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.start,
              ),
            ),
            if (burnedKcal != null)
              Expanded(
                child: _KcalStat(
                  label: 'BURNED',
                  kcal: burnedKcal!,
                  color: LuminaHealthColors.tertiary,
                  alignment: CrossAxisAlignment.end,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// One labelled kcal figure in the stats row under the ring.
class _KcalStat extends StatelessWidget {
  const _KcalStat({
    required this.label,
    required this.kcal,
    required this.color,
    required this.alignment,
  });

  final String label;
  final int kcal;
  final Color color;
  final CrossAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: alignment,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
            letterSpacing: 2.0,
            color: scheme.onSurfaceVariant,
          ),
        ),
        Row(
          mainAxisAlignment: switch (alignment) {
            CrossAxisAlignment.end => MainAxisAlignment.end,
            CrossAxisAlignment.center => MainAxisAlignment.center,
            _ => MainAxisAlignment.start,
          },
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$kcal',
              style: theme.textTheme.headlineLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              'kcal',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
