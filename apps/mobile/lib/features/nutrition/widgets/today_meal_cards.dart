import 'package:flutter/material.dart';
import '../../../ui_system/lumina_health_theme.dart';
import '../../../ui_system/tokens.dart';
import '../data/food_models.dart';
import '../data/nutrition_api_service.dart';
import 'amount_sheet.dart' show FoodImage;

// Today page: daily-logs heading and per-meal cards (KAN-124: extracted
// from nutrition_today_page.dart).

class MealSummary {
  const MealSummary({
    required this.name,
    required this.mealType,
    required this.icon,
    required this.color,
    required this.entries,
  });

  final String name;
  final MealType mealType;
  final IconData icon;

  /// Per-meal accent (KAN-3): tints the card's icon chip and carries into the
  /// detail sheet header so the meal keeps its identity across surfaces.
  final Color color;
  final List<NutritionEntry> entries;

  int get totalKcal => displayKcalTotal(entries);
}

/// "Daily Logs" section heading with the day's entry count.
class DailyLogsHeader extends StatelessWidget {
  const DailyLogsHeader({super.key, required this.totalEntries});

  final int totalEntries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Text(
              'Daily Logs',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
              ),
            ),
          ),
          Text(
            '$totalEntries entries',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class TodayMealCard extends StatelessWidget {
  const TodayMealCard({
    super.key,
    required this.meal,
    required this.onTap,
    required this.onAddFood,
    this.onCopyPreviousDay,
    this.copyPreviousDayLabel = 'Copy from yesterday',
  });

  final MealSummary meal;
  final VoidCallback onTap;

  /// An empty meal has no detail sheet to open, so its tap becomes a logging
  /// shortcut instead: straight to add-food with this meal preselected
  /// (KAN-36). The trailing affordance flips to a "+" to match.
  final VoidCallback onAddFood;

  /// One-tap repeat of the previous day's version of this meal (KAN-51).
  /// Non-null only while the meal is empty and the previous day is known
  /// locally to have entries for it.
  final VoidCallback? onCopyPreviousDay;
  final String copyPreviousDayLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final hasItems = meal.entries.isNotEmpty;
    final firstImage = hasItems
        ? meal.entries.first.foodItem.imageUrl?.trim()
        : null;
    final imageUrl = (firstImage != null && firstImage.isNotEmpty)
        ? firstImage
        : null;

    // Meal-accent chip (KAN-3): each meal's icon sits on a wash of its own
    // accent so the four cards scan apart at a glance even before reading.
    final fallbackIcon = Container(
      color: meal.color.withValues(alpha: 0.12),
      child: Center(child: Icon(meal.icon, color: meal.color)),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: hasItems ? onTap : onAddFood,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: LuminaHealthColors.hairline),
          ),
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: LuminaHealthColors.innerHighlight),
                ),
                clipBehavior: Clip.antiAlias,
                // FoodImage adds the loading placeholder + retry-on-error the
                // raw Image.network lacked, and decodes at the 64px slot size
                // instead of the photo's native resolution (KAN-60).
                child: imageUrl != null
                    ? FoodImage(url: imageUrl, cacheWidth: 64)
                    : fallbackIcon,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Text(
                            meal.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        // scaleDown keeps the full figure visible at large
                        // text scales; an ellipsized kcal would be useless.
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${meal.totalKcal} kcal',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hasItems
                          ? meal.entries.map((e) => e.foodItem.name).join(', ')
                          : 'No foods logged yet.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (onCopyPreviousDay != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: Key('copyPrevious-${meal.mealType.wireName}'),
                          onPressed: onCopyPreviousDay,
                          icon: const Icon(Icons.history, size: 18),
                          label: Text(copyPreviousDayLabel),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(
                hasItems ? Icons.chevron_right : Icons.add_circle_outline,
                color: hasItems ? scheme.onSurfaceVariant : scheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
