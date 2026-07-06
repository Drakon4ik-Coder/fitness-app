import 'package:flutter/material.dart';

import '../../ui_components/ui_components.dart';
import '../../ui_system/lumina_health_theme.dart';
import '../../ui_system/tokens.dart';
import 'data/nutrient_catalog.dart';
import 'data/nutrition_api_service.dart';
import 'widgets/nutrient_breakdown_view.dart';
import 'widgets/nutrient_contributor_sheet.dart';

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
    this.nutrientGoals,
  });

  final String dateLabel;
  final int eatenKcal;
  final List<NutritionEntry> entries;

  /// The server's per-day `nutrients` map when the day payload carried one.
  /// Preferred over on-device aggregation; falls back to [entries] when null
  /// (offline reads / older cached payloads).
  final Map<String, dynamic>? serverNutrients;

  /// The user's per-nutrient goal overrides (catalog key → target). Layered over
  /// the catalog defaults so this page's targets match the today page's.
  final Map<String, double>? nutrientGoals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final catalog = resolveCatalog(nutrientGoals);
    final totals = serverNutrients != null
        ? nutrientTotalsFromServer(serverNutrients!, catalog: catalog)
        : aggregateNutrients(entries, catalog: catalog);

    return AppScaffold(
      safeArea: true,
      padding: EdgeInsets.zero,
      appBar: AppBar(title: const Text('Nutrients'), centerTitle: false),
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
          else ...[
            Row(
              children: [
                Icon(
                  Icons.touch_app_outlined,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Tap any nutrient to see its top food sources.',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            NutrientBreakdownView(
              totals: totals,
              onNutrientTap: (total) => showNutrientContributorSheet(
                context,
                spec: total.spec,
                entries: entries,
              ),
            ),
          ],
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
        border: Border.all(color: LuminaHealthColors.hairline),
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
