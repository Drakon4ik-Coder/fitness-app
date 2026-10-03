import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;
import '../../../ui_system/tokens.dart';
import '../food_search_results.dart';
import 'amount_sheet.dart';

// Add-food search results: cards, section header, empty state and the
// FatSecret attribution (KAN-124: extracted from add_food_page.dart).

/// FatSecret's free-tier attribution link (KAN-67 legal requirement).
const String kFatSecretAttributionUrl = 'https://platform.fatsecret.com';

/// The results-section heading plus the Recent/Favorites toggle (shown only
/// when browsing without a query — pass a null [toggleLabel] to hide it).
class FoodResultsHeader extends StatelessWidget {
  const FoodResultsHeader({
    super.key,
    required this.heading,
    required this.toggleLabel,
    required this.onToggleFilter,
  });

  final String heading;
  final String? toggleLabel;
  final VoidCallback onToggleFilter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              heading.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 2.0,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (toggleLabel != null)
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
              ),
              onPressed: onToggleFilter,
              child: Text(
                toggleLabel!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Empty results state: nudges toward search/scan when browsing, or toward a
/// respelling/scan/custom food when a query found nothing.
class EmptyFoodResults extends StatelessWidget {
  const EmptyFoodResults({
    super.key,
    required this.query,
    required this.onCreateCustomFood,
  });

  final String query;
  final VoidCallback onCreateCustomFood;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasQuery = query.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
      child: Center(
        child: Column(
          children: [
            Icon(
              hasQuery ? Icons.search_off : Icons.restaurant_menu,
              size: 40,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              hasQuery
                  ? 'No foods found for "$query"'
                  : 'Search for a food or scan a barcode',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (hasQuery) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Try a different spelling or scan the package.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: onCreateCustomFood,
              icon: const Icon(Icons.add),
              label: const Text('Create custom food'),
            ),
          ],
        ),
      ),
    );
  }
}

class FoodResultCard extends StatelessWidget {
  const FoodResultCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.isAdded = false,
    this.isEnriching = false,
  });

  final FoodResult item;
  final VoidCallback onTap;

  /// Long-press action — opens the read-first food detail page (KAN-35).
  final VoidCallback? onLongPress;
  final bool isAdded;
  final bool isEnriching;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(AppRadius.lg * 1.5);

    final imageUrl = item.item.imageUrl?.trim().isNotEmpty == true
        ? item.item.imageUrl!.trim()
        : null;

    return Semantics(
      button: true,
      label: isAdded
          ? '${item.item.name}, added. Edit amount'
          : 'Add ${item.item.name}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: isEnriching ? null : onTap,
          onLongPress: isEnriching ? null : onLongPress,
          child: Ink(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: radius,
              border: Border.all(
                color: isAdded ? scheme.primary : Colors.transparent,
                width: isAdded ? 2 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Image / placeholder / retry layer.
                  FoodImage(url: imageUrl),
                  // Bottom gradient keeps the white name text legible over both
                  // real photos and the placeholder.
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.8),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (isEnriching)
                    Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.35),
                        child: Center(
                          child: SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: scheme.onPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (isAdded)
                    Positioned(
                      top: AppSpacing.sm,
                      right: AppSpacing.sm,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check,
                          size: 14,
                          color: scheme.onPrimary,
                        ),
                      ),
                    ),
                  // The user's own foods are marked so it's clear these
                  // values are theirs, not the shared catalog's.
                  if (item.item.isCustom)
                    Positioned(
                      top: AppSpacing.sm,
                      left: AppSpacing.sm,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          item.item.isOverride ? 'Edited by you' : 'Yours',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSecondaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: AppSpacing.sm,
                    right: AppSpacing.sm,
                    bottom: AppSpacing.sm,
                    child: Text(
                      item.item.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Free-tier attribution FatSecret's platform terms require (KAN-67).
/// Extracted per the size-discipline rule; muted labelSmall/onSurfaceVariant
/// styling so it reads as a footnote, not another result.
class FatSecretAttributionFooter extends StatelessWidget {
  const FatSecretAttributionFooter({super.key});

  Future<void> _open() {
    return url_launcher.launchUrl(
      Uri.parse(kFatSecretAttributionUrl),
      mode: url_launcher.LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _open,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              child: Text(
                'Powered by FatSecret',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
