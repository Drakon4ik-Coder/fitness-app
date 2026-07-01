import 'package:flutter/material.dart';

import '../../ui_components/ui_components.dart';
import '../../ui_system/lumina_health_theme.dart';
import '../../ui_system/tokens.dart';
import 'data/nutrient_catalog.dart';
import 'data/nutrition_api_service.dart';

/// Full per-day nutrient breakdown, grouped into Macros / Vitamins / Minerals /
/// Other. Every value is computed on-device from each logged food's stored OFF
/// nutriments blob (scaled by the logged quantity) — no extra network call.
///
/// The today page stays the glanceable hero; this is the progressive-disclosure
/// detail behind a "View full nutrients" tap.
class NutritionDetailPage extends StatelessWidget {
  const NutritionDetailPage({
    super.key,
    required this.dateLabel,
    required this.eatenKcal,
    required this.entries,
    this.serverNutrients,
  });

  final String dateLabel;
  final int eatenKcal;
  final List<NutritionEntry> entries;

  /// The server's per-day `nutrients` map when the day payload carried one.
  /// Preferred over on-device aggregation; falls back to [entries] when null
  /// (offline reads / older cached payloads).
  final Map<String, dynamic>? serverNutrients;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final totals = serverNutrients != null
        ? nutrientTotalsFromServer(serverNutrients!)
        : aggregateNutrients(entries);
    final byGroup = <NutrientGroup, List<NutrientTotal>>{};
    for (final total in totals) {
      byGroup.putIfAbsent(total.spec.group, () => []).add(total);
    }

    return AppScaffold(
      safeArea: true,
      padding: EdgeInsets.zero,
      appBar: AppBar(
        title: const Text('Nutrients'),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        children: [
          Text(
            dateLabel.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 2.0,
              fontWeight: FontWeight.bold,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _EnergyHeader(eatenKcal: eatenKcal),
          const SizedBox(height: AppSpacing.lg),
          if (entries.isEmpty)
            _EmptyState(scheme: scheme, theme: theme)
          else
            for (final group in NutrientGroup.values)
              if ((byGroup[group] ?? const []).isNotEmpty)
                _NutrientGroupSection(
                  title: group.label,
                  totals: byGroup[group]!,
                ),
        ],
      ),
    );
  }
}

class _EnergyHeader extends StatelessWidget {
  const _EnergyHeader({required this.eatenKcal});

  final int eatenKcal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            'Energy',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: scheme.onSurface,
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$eatenKcal',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: scheme.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
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
      ),
    );
  }
}

class _NutrientGroupSection extends StatelessWidget {
  const _NutrientGroupSection({required this.title, required this.totals});

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
                _NutrientRow(total: totals[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _NutrientRow extends StatelessWidget {
  const _NutrientRow({required this.total});

  final NutrientTotal total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final spec = total.spec;
    final hasData = total.hasData;
    final over = total.isOverLimit;

    final Color barColor = over
        ? LuminaHealthColors.warning
        : scheme.primary;
    final valueColor = over
        ? LuminaHealthColors.warning
        : (hasData ? scheme.onSurface : scheme.onSurfaceVariant);

    final String amountText = hasData
        ? '${_fmt(total.amount!)} / ${_fmt(spec.dailyTarget)} ${spec.unit}'
        : '— no data';
    final String? percentText = hasData
        ? '${(total.amount! / spec.dailyTarget * 100).round()}%'
        : null;

    return Semantics(
      label: hasData
          ? '${spec.label}, ${_fmt(total.amount!)} of ${_fmt(spec.dailyTarget)} '
                '${spec.unit}, ${percentText!} of target'
          : '${spec.label}, no data',
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
                    if (percentText != null) ...[
                      const SizedBox(width: AppSpacing.sm),
                      SizedBox(
                        width: 38,
                        child: Text(
                          percentText,
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: valueColor,
                            fontWeight: FontWeight.bold,
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.scheme, required this.theme});

  final ColorScheme scheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xxl),
      child: Column(
        children: [
          Icon(
            Icons.eco_outlined,
            size: 40,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'No foods logged yet',
            style: theme.textTheme.titleSmall?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Log a meal to see its vitamins and minerals here.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact number: up to one decimal below 10 (e.g. `2.4`), whole numbers above
/// (e.g. `120`), so mixed-magnitude nutrient columns stay readable.
String _fmt(double value) {
  if (value >= 10) return value.round().toString();
  final oneDp = (value * 10).round() / 10;
  if (oneDp == oneDp.roundToDouble()) return oneDp.round().toString();
  return oneDp.toStringAsFixed(1);
}
