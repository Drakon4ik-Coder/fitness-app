import 'package:flutter/material.dart';

import '../../../ui_system/tokens.dart';
import '../data/food_models.dart';
import '../data/nutrient_catalog.dart';
import '../data/nutrition_api_service.dart';
import 'nutrient_breakdown_view.dart';

/// Opens the "who contributes this nutrient" sheet for [spec], ranking the day's
/// logged [entries] by how much of the nutrient each carries. Called when a
/// nutrient row on the detail page is tapped.
///
/// [onEditFood] powers the "no data" rows (KAN-92): it opens the edit flow for
/// a food missing the nutrient and resolves with the day's refreshed entries
/// when the edit changed something (null = unchanged), so the sheet can re-rank
/// in place and the edited food moves out of the missing section. When null the
/// missing foods still render, just without a tap affordance.
Future<void> showNutrientContributorSheet(
  BuildContext context, {
  required NutrientSpec spec,
  required List<NutritionEntry> entries,
  Future<List<NutritionEntry>?> Function(FoodItem item)? onEditFood,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _NutrientContributorSheet(
      spec: spec,
      entries: entries,
      onEditFood: onEditFood,
    ),
  );
}

class _NutrientContributorSheet extends StatefulWidget {
  const _NutrientContributorSheet({
    required this.spec,
    required this.entries,
    this.onEditFood,
  });

  final NutrientSpec spec;
  final List<NutritionEntry> entries;
  final Future<List<NutritionEntry>?> Function(FoodItem item)? onEditFood;

  @override
  State<_NutrientContributorSheet> createState() =>
      _NutrientContributorSheetState();
}

class _NutrientContributorSheetState extends State<_NutrientContributorSheet> {
  // Held as state (not derived in build) so an edit can re-rank the open sheet
  // from the refreshed entries without reopening it.
  late NutrientContributionBreakdown _breakdown = nutrientContributors(
    widget.entries,
    widget.spec,
  );

  Future<void> _editFood(FoodItem item) async {
    final refreshed = await widget.onEditFood!(item);
    if (!mounted || refreshed == null) return;
    setState(() => _breakdown = nutrientContributors(refreshed, widget.spec));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final breakdown = _breakdown;
    final spec = breakdown.spec;
    final contributors = breakdown.contributors;
    final missing = breakdown.missingFoods;
    // The missing section adds a header row before its food rows.
    final missingRowCount = missing.isEmpty ? 0 : missing.length + 1;

    return DraggableScrollableSheet(
      initialChildSize: contributors.length + missingRowCount > 4 ? 0.6 : 0.45,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.lg * 1.5),
            ),
          ),
          child: Column(
            children: [
              // Drag handle
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              _Header(breakdown: breakdown),
              Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
              Expanded(
                // Even with zero contributors the missing foods still render:
                // "every food lacks this" is exactly when the user most needs
                // to see which foods to fix (KAN-92).
                child: contributors.isEmpty && missing.isEmpty
                    ? _EmptyState(spec: spec)
                    : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          AppSpacing.md,
                          AppSpacing.lg,
                          AppSpacing.sm,
                        ),
                        itemCount: contributors.length + missingRowCount,
                        itemBuilder: (context, index) {
                          if (index < contributors.length) {
                            return _ContributorRow(
                              rank: index + 1,
                              contribution: contributors[index],
                              unit: spec.unit,
                              leading: index == 0,
                            );
                          }
                          final missingIndex = index - contributors.length - 1;
                          if (missingIndex < 0) {
                            return _MissingHeader(
                              label: spec.label,
                              canEdit: widget.onEditFood != null,
                            );
                          }
                          final food = missing[missingIndex];
                          return _MissingFoodRow(
                            food: food,
                            onEdit: widget.onEditFood == null
                                ? null
                                : () => _editFood(food.item),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.breakdown});

  final NutrientContributionBreakdown breakdown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final spec = breakdown.spec;
    final hasTotal = breakdown.total > 0;
    final pctOfTarget = spec.dailyTarget > 0
        ? (breakdown.total / spec.dailyTarget * 100).round()
        : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TOP SOURCES',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  spec.label,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          if (hasTotal)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      formatNutrientValue(breakdown.total),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: scheme.primary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      spec.unit,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (pctOfTarget != null)
                  Text(
                    '$pctOfTarget% of daily target',
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

class _ContributorRow extends StatelessWidget {
  const _ContributorRow({
    required this.rank,
    required this.contribution,
    required this.unit,
    required this.leading,
  });

  final int rank;
  final NutrientContribution contribution;
  final String unit;
  final bool leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // The top source gets the full-strength brand color; the rest step down so
    // the ranking reads at a glance without leaning on numbers alone.
    final barColor = leading
        ? scheme.primary
        : scheme.primary.withValues(alpha: 0.55);
    final pct = (contribution.share * 100).round();
    final subtitle = contribution.brand.isNotEmpty
        ? '${contribution.brand} · ${formatNutrientValue(contribution.quantityG)} g'
        : '${formatNutrientValue(contribution.quantityG)} g';

    return Semantics(
      label:
          '#$rank contributor, ${contribution.name}, '
          '${formatNutrientValue(contribution.amount)} $unit, '
          '$pct% of the total',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '$rank',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        contribution.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${formatNutrientValue(contribution.amount)} $unit',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      '$pct%',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.bold,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.only(left: 22),
              child: LinearProgressIndicator(
                value: contribution.share.clamp(0.0, 1.0),
                backgroundColor: scheme.surfaceContainerHighest,
                color: barColor,
                minHeight: 5,
                borderRadius: BorderRadius.circular(9999),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MissingHeader extends StatelessWidget {
  const _MissingHeader({required this.label, required this.canEdit});

  final String label;
  final bool canEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final explainer = canEdit
        ? 'These foods report no $label, so the total is a floor — '
              'tap one to fill it in.'
        : 'These foods report no $label, so the total is a floor.';
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'NO DATA FOR ${label.toUpperCase()}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 1.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            explainer,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _MissingFoodRow extends StatelessWidget {
  const _MissingFoodRow({required this.food, this.onEdit});

  final MissingNutrientFood food;

  /// Opens the edit flow for this food; null renders the row inert (no
  /// affordance) for callers that can't offer editing.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = food.item;
    // Muted vs. contributor rows on purpose: these foods don't move the total.
    final subtitle = item.brands.isNotEmpty
        ? '${item.brands} · ${formatNutrientValue(food.quantityG)} g'
        : '${formatNutrientValue(food.quantityG)} g';

    return Semantics(
      button: onEdit != null,
      label:
          '${item.name}, no data'
          '${onEdit != null ? ', tap to edit its nutrition facts' : ''}',
      child: InkWell(
        onTap: onEdit,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              if (onEdit != null) ...[
                const SizedBox(width: AppSpacing.sm),
                Icon(
                  Icons.edit_outlined,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.spec});

  final NutrientSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: 36,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'No source data',
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'None of today\'s foods report ${spec.label}.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
