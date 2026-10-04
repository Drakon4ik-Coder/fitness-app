import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import '../../../ui_system/lumina_health_theme.dart';
import '../../../ui_system/tokens.dart';
import '../data/food_models.dart';
import '../data/nutrient_catalog.dart';
import 'amount_sheet.dart';
import 'nutrient_breakdown_view.dart' show formatNutrientValue;
import 'swipe_delete_background.dart';

// The add-food page's staging area: meal selector, nutrient summary and
// the staged-items list (KAN-124: extracted from add_food_page.dart).

/// Compact amount + unit for the summary rows ("32g", "120 mg").
String _focusValueText(double value, String unit) =>
    '${formatNutrientValue(value)}${unit == 'g' ? 'g' : ' $unit'}';

// Fraction of a nutrient's daily target treated as "one meal's worth", giving
// the summary bars a meaningful scale. Uses each focus nutrient's (possibly
// personalized) daily target, so the bars track the user's own goals.
const double _mealShareOfDailyTarget = 0.3;

/// A food the user has chosen to log, paired with the amount (grams) to log.
class AddedFood {
  const AddedFood({required this.item, required this.grams});

  final FoodItem item;
  final double grams;
}

/// The tappable row showing which meal the staged items will be logged to.
class MealTypeSelectorTile extends StatelessWidget {
  const MealTypeSelectorTile({
    super.key,
    required this.meal,
    required this.onTap,
  });

  final MealType meal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  // The selected meal's own icon + accent (KAN-3) so the
                  // destination reads at a glance, matching the today page.
                  Icon(mealTypeIcon(meal), color: mealTypeAccent(meal)),
                  const SizedBox(width: AppSpacing.md),
                  Flexible(
                    child: Text(
                      meal.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.expand_more, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// The bento summary pair: total energy of the staged items next to their
/// focus-nutrient totals (same nutrients the today page tracks).
class StagedSummaryBento extends StatelessWidget {
  const StagedSummaryBento({
    super.key,
    required this.totalKcal,
    required this.focusSpecs,
    required this.focusTotals,
  });

  final int totalKcal;
  final List<NutrientSpec> focusSpecs;
  final List<double> focusTotals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // A min-height instead of a fixed height so large system text scales
    // grow the cards rather than clipping them; IntrinsicHeight keeps the
    // two cards equal (KAN-40).
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 140),
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'TOTAL ENERGY',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 2.0,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  // The hero figure shrinks to fit rather than overflowing the
                  // half-width card at large system text scales (KAN-40).
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          totalKcal.toString(),
                          style: theme.textTheme.displayMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: scheme.primary,
                            height: 1,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'kcal',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              constraints: const BoxConstraints(minHeight: 140),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (var i = 0; i < focusSpecs.length; i++)
                    _MacroSummaryRow(
                      label: focusSpecs[i].label,
                      value: _focusValueText(
                        focusTotals[i],
                        focusSpecs[i].unit,
                      ),
                      color:
                          LuminaHealthColors.focusAccents[i %
                              LuminaHealthColors.focusAccents.length],
                      progress:
                          (focusTotals[i] /
                                  (focusSpecs[i].dailyTarget *
                                      _mealShareOfDailyTarget))
                              .clamp(0.0, 1.0),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MacroSummaryRow extends StatelessWidget {
  const _MacroSummaryRow({
    required this.label,
    required this.value,
    required this.color,
    required this.progress,
  });

  final String label;
  final String value;
  final Color color;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 0,
                ),
              ),
            ),
            // scaleDown keeps the full amount visible at large text scales;
            // an ellipsized figure would be useless.
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: progress,
          backgroundColor: Theme.of(context).colorScheme.surfaceBright,
          color: color,
          minHeight: 4,
          borderRadius: BorderRadius.circular(999),
        ),
      ],
    );
  }
}

/// The "ADDED ITEMS" label plus staged tiles, extracted from build() while
/// restructuring the page into slivers (KAN-60). Tap edits the logged amount;
/// long-press inspects the food itself (KAN-35) — same model as the results
/// grid.
class AddedItemsSection extends StatelessWidget {
  const AddedItemsSection({
    super.key,
    required this.items,
    required this.onEdit,
    required this.onInspect,
    required this.onRemove,
  });

  final List<AddedFood> items;
  final void Function(int index) onEdit;
  final void Function(FoodItem item) onInspect;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.lg),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Text(
            'ADDED ITEMS',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 2.0,
              fontWeight: FontWeight.bold,
              fontSize: 10,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        for (final (index, added) in items.indexed)
          _AddedItemTile(
            added: added,
            onTap: () => onEdit(index),
            onLongPress: () => onInspect(added.item),
            onRemove: () => onRemove(index),
          ),
      ],
    );
  }
}

/// One staged item in the Added list: thumb plus amount + kcal line. Tap
/// edits, swipe (endToStart) removes with Undo (KAN-39) — no persistent
/// remove button, and the editor's "Remove from meal" is the visible path.
class _AddedItemTile extends StatelessWidget {
  const _AddedItemTile({
    required this.added,
    required this.onTap,
    required this.onLongPress,
    required this.onRemove,
  });

  final AddedFood added;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final grams = added.grams;
    final kcal = ((added.item.kcal100g ?? 0) * grams / 100).round();
    final amountLabel = describeAmount(grams, added.item);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Dismissible(
        key: ObjectKey(added),
        // endToStart only, so the swipe never fights the Android back
        // gesture on the left edge.
        direction: DismissDirection.endToStart,
        background: SwipeDeleteBackground(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        onDismissed: (_) => onRemove(),
        // The swipe gesture is invisible to screen readers; expose the
        // removal as an explicit accessibility action instead.
        child: Semantics(
          customSemanticsActions: {
            CustomSemanticsAction(label: 'Remove ${added.item.name}'): onRemove,
          },
          child: Material(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              onTap: onTap,
              onLongPress: onLongPress,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    FoodThumb(
                      url: added.item.imageUrl?.trim().isNotEmpty == true
                          ? added.item.imageUrl!.trim()
                          : null,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            added.item.name,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '$amountLabel • $kcal kcal',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
