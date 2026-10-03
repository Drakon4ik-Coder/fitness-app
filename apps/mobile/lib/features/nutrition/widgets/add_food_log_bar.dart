import 'package:flutter/material.dart';
import '../../../ui_system/tokens.dart';

// Add-food page bottom action bar (KAN-124: extracted from
// add_food_page.dart).

/// Persistent bottom action bar — the single primary CTA for committing the
/// meal. Surfaces the live item count + total calories so the user knows
/// exactly what they are logging, and shows an inline spinner while submitting.
class AddFoodLogBar extends StatelessWidget {
  const AddFoodLogBar({
    super.key,
    required this.itemCount,
    required this.totalKcal,
    required this.mealLabel,
    required this.isSubmitting,
    required this.onSubmit,
  });

  final int itemCount;
  final int totalKcal;
  final String mealLabel;
  final bool isSubmitting;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final itemLabel = itemCount == 1 ? '1 item' : '$itemCount items';

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      itemLabel,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '$totalKcal kcal total',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Flexible(
                child: FilledButton(
                  onPressed: isSubmitting ? null : onSubmit,
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                    disabledBackgroundColor: scheme.primary.withValues(
                      alpha: 0.5,
                    ),
                    minimumSize: const Size(0, 52),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  child: isSubmitting
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: scheme.onPrimary,
                          ),
                        )
                      : Text(
                          'Log to $mealLabel',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: scheme.onPrimary,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
