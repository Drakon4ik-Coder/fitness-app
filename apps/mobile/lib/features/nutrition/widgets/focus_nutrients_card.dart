import 'package:flutter/material.dart';
import '../../../ui_system/lumina_health_theme.dart';
import '../../../ui_system/tokens.dart';
import '../data/nutrient_catalog.dart';
import 'nutrient_breakdown_view.dart' show formatNutrientValue;

// Today page: focus-nutrient card, its tiles and day-state model (KAN-124:
// extracted from nutrition_today_page.dart).

/// One focus nutrient's day state. [amount] is in the spec's canonical unit;
/// null means foods were logged but none reported this nutrient.
class FocusSummary {
  const FocusSummary({
    required this.spec,
    required this.amount,
    this.incomplete = false,
  });

  final NutrientSpec spec;
  final double? amount;

  /// The total is a floor — some of the day's foods didn't report it.
  final bool incomplete;
}

/// The bordered focus-nutrients card: a single row of tiles for up to three,
/// a 2×2 grid for four (four labels + values in one row would be cramped).
/// Slot accents come from [LuminaHealthColors.focusAccents] so the card
/// matches the amount-sheet pills and add-meal summary.
class FocusNutrientsCard extends StatelessWidget {
  const FocusNutrientsCard({
    super.key,
    required this.summaries,
    required this.warnNutrients,
  });

  final List<FocusSummary> summaries;
  final Set<String> warnNutrients;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tiles = [
      for (var i = 0; i < summaries.length; i++)
        Expanded(
          child: _FocusTile(
            summary: summaries[i],
            accent: LuminaHealthColors
                .focusAccents[i % LuminaHealthColors.focusAccents.length],
            warnNutrients: warnNutrients,
          ),
        ),
    ];
    const gap = SizedBox(width: AppSpacing.md);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: LuminaHealthColors.hairline),
        boxShadow: [
          BoxShadow(
            color: LuminaHealthColors.hairline,
            offset: const Offset(0, 2),
            blurRadius: 4,
            spreadRadius: 0,
            blurStyle: BlurStyle.inner,
          ),
        ],
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: tiles.length <= 3
          ? Row(
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) gap,
                  tiles[i],
                ],
              ],
            )
          : Column(
              children: [
                Row(children: [tiles[0], gap, tiles[1]]),
                const SizedBox(height: AppSpacing.md),
                Row(children: [tiles[2], gap, tiles[3]]),
              ],
            ),
    );
  }
}

// How a nutrient reads once its goal is exceeded (KAN-38): amber only when the
// user opted the nutrient into warnings; restrict-type nutrients over are
// neutral information; target-type nutrients — protein, fiber, vitamins,
// minerals — hit their target, which is the goal, so they celebrate.
({Color textColor, Color barColor, String suffix}) _overTreatmentColors(
  NutrientSpec spec,
  Color accent,
  Set<String> warnNutrients,
) {
  switch (overGoalTreatment(spec, warnNutrients)) {
    case OverGoalTreatment.warn:
      return (
        textColor: LuminaHealthColors.warning,
        barColor: LuminaHealthColors.warning,
        suffix: 'over',
      );
    case OverGoalTreatment.neutral:
      return (
        textColor: LuminaHealthColors.onSurfaceVariant,
        barColor: accent,
        suffix: 'over',
      );
    case OverGoalTreatment.celebrate:
      return (textColor: accent, barColor: accent, suffix: '✓');
  }
}

/// One focus nutrient's tile: label + amount, progress toward the goal, and
/// the left/over/incomplete/no-data status line.
class _FocusTile extends StatelessWidget {
  const _FocusTile({
    required this.summary,
    required this.accent,
    required this.warnNutrients,
  });

  final FocusSummary summary;
  final Color accent;
  final Set<String> warnNutrients;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final spec = summary.spec;
    // Grams read as "150g"; other units keep a thin space ("320 mg").
    final unit = spec.unit == 'g' ? 'g' : ' ${spec.unit}';

    final amount = summary.amount;
    final noData = amount == null;
    final goal = spec.dailyTarget;
    final over = noData ? 0.0 : amount - goal;
    // A floor total's over/left is unreliable, so the incomplete hint takes
    // precedence over over-limit.
    final incomplete = !noData && summary.incomplete;
    final isOver = !noData && !incomplete && over > 0;
    final progress = noData || goal <= 0
        ? 0.0
        : (amount / goal).clamp(0.0, 1.0).toDouble();
    final treatment = isOver
        ? _overTreatmentColors(spec, accent, warnNutrients)
        : null;
    final barColor = incomplete
        ? accent.withValues(alpha: 0.35)
        : treatment?.barColor ?? accent;
    final valueColor = noData || incomplete
        ? scheme.onSurfaceVariant
        : treatment?.textColor ?? accent;
    final valueText = noData
        ? '—'
        : '${incomplete ? '~' : ''}${formatNutrientValue(amount)}$unit';
    final statusText = noData
        ? 'no data'
        : incomplete
        ? 'incomplete'
        : isOver
        ? '+${formatNutrientValue(over)}$unit ${treatment!.suffix}'
        : '${formatNutrientValue(goal - amount)}$unit left';
    final statusColor = noData || incomplete
        ? scheme.onSurfaceVariant
        : treatment?.textColor ?? scheme.onSurface.withValues(alpha: 0.6);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                spec.label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurfaceVariant,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            Text(
              valueText,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: valueColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        LinearProgressIndicator(
          value: progress,
          backgroundColor: scheme.surfaceContainerHighest,
          color: barColor,
          minHeight: 6,
          borderRadius: BorderRadius.circular(9999),
        ),
        const SizedBox(height: AppSpacing.xs),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            statusText,
            // Muted color + the value's "~" prefix already mark estimates;
            // italic at this size only hurt legibility (KAN-40).
            style: theme.textTheme.labelSmall?.copyWith(
              color: statusColor,
              fontWeight: isOver ? FontWeight.bold : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// The tappable row leading to the full vitamins/minerals breakdown page.
class ViewFullNutrientsLink extends StatelessWidget {
  const ViewFullNutrientsLink({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                Icon(Icons.insights, size: 18, color: scheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'View full nutrients',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
