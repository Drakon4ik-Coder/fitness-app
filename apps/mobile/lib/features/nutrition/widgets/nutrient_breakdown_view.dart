import 'package:flutter/material.dart';

import '../../../ui_system/lumina_health_theme.dart';
import '../../../ui_system/tokens.dart';
import '../data/nutrient_catalog.dart';

/// Grouped nutrient breakdown (Macros / Vitamins / Minerals / Other), shared by
/// the full-day detail page and the per-food view inside the meal-detail sheet.
///
/// [showEmptyRows] controls the "no data" treatment: the full-day view shows
/// every catalog nutrient (so users see what's tracked, absent = "— no data"),
/// while the compact per-food view passes `false` to list only nutrients the
/// food actually carries, falling back to [emptyDataMessage] when it has none.
class NutrientBreakdownView extends StatelessWidget {
  const NutrientBreakdownView({
    super.key,
    required this.totals,
    this.showEmptyRows = true,
    this.emptyDataMessage = 'No detailed nutrient data for this food.',
  });

  final List<NutrientTotal> totals;
  final bool showEmptyRows;
  final String emptyDataMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final byGroup = <NutrientGroup, List<NutrientTotal>>{};
    for (final total in totals) {
      if (!showEmptyRows && !total.hasData) continue;
      byGroup.putIfAbsent(total.spec.group, () => []).add(total);
    }

    final sections = [
      for (final group in NutrientGroup.values)
        if ((byGroup[group] ?? const []).isNotEmpty)
          NutrientGroupSection(title: group.label, totals: byGroup[group]!),
    ];

    if (sections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Text(
          emptyDataMessage,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: sections,
    );
  }
}

class NutrientGroupSection extends StatelessWidget {
  const NutrientGroupSection({
    super.key,
    required this.title,
    required this.totals,
  });

  final String title;
  final List<NutrientTotal> totals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xs,
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.sm,
          ),
          child: Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 1.5,
              fontWeight: FontWeight.bold,
              fontSize: 11,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: Column(
            children: [
              for (var i = 0; i < totals.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
                NutrientRow(total: totals[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class NutrientRow extends StatelessWidget {
  const NutrientRow({super.key, required this.total});

  final NutrientTotal total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final spec = total.spec;
    final hasData = total.hasData;
    final incomplete = total.isIncomplete;
    // An incomplete total is a floor, so its over-limit / % are unreliable —
    // the incomplete treatment takes precedence.
    final over = !incomplete && total.isOverLimit;

    final Color barColor = incomplete
        ? scheme.primary.withValues(alpha: 0.35)
        : over
            ? LuminaHealthColors.warning
            : scheme.primary;
    final valueColor = over
        ? LuminaHealthColors.warning
        : (hasData ? scheme.onSurface : scheme.onSurfaceVariant);

    // Incomplete totals lead with "~" (at least this much) and a "partial"
    // tag instead of a confident %.
    final String amountText = !hasData
        ? '— no data'
        : '${incomplete ? '~' : ''}${formatNutrientValue(total.amount!)} / '
              '${formatNutrientValue(spec.dailyTarget)} ${spec.unit}';
    final String? trailingText = !hasData
        ? null
        : incomplete
            ? 'partial'
            : '${(total.amount! / spec.dailyTarget * 100).round()}%';
    final Color trailingColor = incomplete ? scheme.onSurfaceVariant : valueColor;

    return Semantics(
      label: !hasData
          ? '${spec.label}, no data'
          : incomplete
              ? '${spec.label}, at least '
                    '${formatNutrientValue(total.amount!)} ${spec.unit}, '
                    'incomplete: ${total.reportedCount} of ${total.totalCount} '
                    'foods reported it'
              : '${spec.label}, ${formatNutrientValue(total.amount!)} of '
                    '${formatNutrientValue(spec.dailyTarget)} ${spec.unit}, '
                    '${trailingText!} of target',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  spec.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: hasData
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      amountText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: valueColor,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (trailingText != null) ...[
                      const SizedBox(width: AppSpacing.sm),
                      SizedBox(
                        width: 52,
                        child: Text(
                          trailingText,
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: trailingColor,
                            fontWeight: FontWeight.bold,
                            fontStyle: incomplete ? FontStyle.italic : null,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            if (hasData) ...[
              const SizedBox(height: AppSpacing.xs),
              LinearProgressIndicator(
                value: total.progress,
                backgroundColor: scheme.surfaceContainerHighest,
                color: barColor,
                minHeight: 5,
                borderRadius: BorderRadius.circular(9999),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact number: up to one decimal below 10 (e.g. `2.4`), whole numbers above
/// (e.g. `120`), so mixed-magnitude nutrient columns stay readable.
String formatNutrientValue(double value) {
  if (value >= 10) return value.round().toString();
  final oneDp = (value * 10).round() / 10;
  if (oneDp == oneDp.roundToDouble()) return oneDp.round().toString();
  return oneDp.toStringAsFixed(1);
}
