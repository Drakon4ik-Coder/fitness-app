import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../ui_components/ui_components.dart';
import '../../ui_system/lumina_health_theme.dart';
import '../../ui_system/tokens.dart';
import 'custom_food_page.dart';
import 'data/api_exceptions.dart';
import 'data/food_local_db.dart';
import 'data/food_models.dart';
import 'data/food_sync.dart';
import 'data/foods_api_service.dart';
import 'data/nutrient_catalog.dart';
import 'widgets/amount_sheet.dart' show FoodImage, formatAmount;
import 'widgets/nutrient_breakdown_view.dart';

/// Pushes the read-first food page (KAN-33) and resolves with the item as
/// last edited inside it, or null when nothing changed — so amount sheets
/// can refresh their preview. Live changes still stream through
/// [onItemChanged] / [onItemReverted] for callers that patch lists in place.
Future<FoodItem?> pushFoodDetailPage(
  BuildContext context, {
  required FoodItem item,
  required FoodsApiService foodsApi,
  required FoodLocalDb localDb,
  required Future<void> Function() onLogout,
  required List<NutrientSpec> catalog,
  void Function(FoodItem updated)? onItemChanged,
  void Function(FoodItem removed)? onItemReverted,
}) async {
  FoodItem? updated;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => FoodDetailPage(
        item: item,
        foodsApi: foodsApi,
        localDb: localDb,
        onLogout: onLogout,
        catalog: catalog,
        onItemChanged: (next) {
          updated = next;
          onItemChanged?.call(next);
        },
        onItemReverted: onItemReverted,
      ),
    ),
  );
  return updated;
}

/// Read-first page for one food (KAN-33): full per-100g nutrition facts,
/// provenance chips explaining where the values come from, and a visible
/// "Edit nutrition facts" action — so editing isn't hidden behind long-press.
///
/// Named FoodDetailPage to avoid colliding with the day-level
/// [NutritionDetailPage]. View and edit stay separate modes: the page links
/// to the existing [CustomFoodPage] form and owns persisting its result
/// (backend upsert + local store), reporting changes back through
/// [onItemChanged] / [onItemReverted] so callers can refresh their lists.
class FoodDetailPage extends StatefulWidget {
  const FoodDetailPage({
    super.key,
    required this.item,
    required this.foodsApi,
    required this.localDb,
    required this.onLogout,
    this.catalog = kNutrientCatalog,
    this.onItemChanged,
    this.onItemReverted,
  });

  final FoodItem item;
  final FoodsApiService foodsApi;
  final FoodLocalDb localDb;
  final Future<void> Function() onLogout;

  /// Nutrient specs (goal-resolved when the caller has preferences) driving
  /// the per-100g breakdown's targets.
  final List<NutrientSpec> catalog;

  /// Fired whenever an edit or favorite toggle produced a new stored item,
  /// so the caller can swap its copies while this page stays open.
  final void Function(FoodItem updated)? onItemChanged;

  /// Fired when the food was reverted (override) or deleted (custom food);
  /// the page pops itself right after.
  final void Function(FoodItem removed)? onItemReverted;

  @override
  State<FoodDetailPage> createState() => _FoodDetailPageState();
}

class _FoodDetailPageState extends State<FoodDetailPage> {
  late FoodItem _item = widget.item;
  bool _busy = false;
  String? _message;

  String? get _imageUrl {
    final url = _item.imageUrl?.trim();
    return (url != null && url.isNotEmpty) ? url : null;
  }

  /// Per-100g totals via the item-aware reader, so older rows carrying only
  /// the flat macro columns (no nutriments blob) still show their macros.
  List<NutrientTotal> get _totalsPer100g => [
    for (final spec in widget.catalog)
      () {
        final per100 = nutrientPer100gForItem(spec, _item);
        return NutrientTotal(
          spec: spec,
          amount: per100,
          reportedCount: per100 != null ? 1 : 0,
          totalCount: 1,
        );
      }(),
  ];

  // ---- Actions ------------------------------------------------------------

  Future<void> _toggleFavorite() async {
    final next = !_item.isFavorite;
    var item = _item;
    if (item.localId == null) {
      // Favoriting implies "keep this around": store the row first.
      item = await widget.localDb.upsertFood(item);
    }
    await widget.localDb.setFavorite(item.localId!, next);
    if (!mounted) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _item = item.copyWith(isFavorite: next));
    widget.onItemChanged?.call(_item);
  }

  /// Opens the nutrition editor: the edit form for the user's own food, or
  /// the fork-on-edit override flow for a catalog item (resolving a backend
  /// id first — the override links to the global row by id).
  Future<void> _edit() async {
    var target = _item;
    if (!target.isCustom && target.backendId == null) {
      setState(() {
        _busy = true;
        _message = null;
      });
      try {
        final (resolved, _) = await ensureGlobalBackendId(
          target,
          foodsApi: widget.foodsApi,
        );
        target = resolved;
        _item = resolved;
      } on ApiException catch (error) {
        if (error.isUnauthorized) {
          await widget.onLogout();
          return;
        }
        if (!mounted) return;
        setState(() {
          _busy = false;
          _message = 'Could not open the editor — check your connection.';
        });
        return;
      }
      if (!mounted) return;
      setState(() => _busy = false);
    }

    final result = await Navigator.of(context).push<CustomFoodResult>(
      MaterialPageRoute(
        builder: (_) => target.isCustom
            ? CustomFoodPage(initial: target)
            : CustomFoodPage(overrideOf: target),
      ),
    );
    if (result == null || !mounted) return;
    if (result.deleted) {
      await _removeCustomFood();
      return;
    }
    final draft = result.item;
    if (draft == null) return;
    final stored = await saveCustomFoodDraft(
      draft,
      foodsApi: widget.foodsApi,
      localDb: widget.localDb,
      onUnauthorized: widget.onLogout,
      onSynced: (synced) {
        if (!mounted) return;
        setState(() => _item = synced);
        widget.onItemChanged?.call(synced);
      },
    );
    if (stored == null || !mounted) return;
    setState(() => _item = stored);
    widget.onItemChanged?.call(stored);
  }

  /// Confirms and reverts an override to the original catalog values
  /// (deleting the personal copy). Mirrors the dialog inside the edit form so
  /// both paths read the same.
  Future<void> _confirmRevert() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revert to the original?'),
        content: const Text(
          'Your corrected values are removed and the catalog item '
          'comes back. Logged meals keep their history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Revert',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _removeCustomFood();
    }
  }

  Future<void> _removeCustomFood() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final outcome = await deleteCustomFoodEverywhere(
      _item,
      foodsApi: widget.foodsApi,
      localDb: widget.localDb,
      onUnauthorized: widget.onLogout,
    );
    if (!mounted) return;
    switch (outcome) {
      case CustomFoodDeleteOutcome.unauthorized:
        return;
      case CustomFoodDeleteOutcome.failed:
        setState(() {
          _busy = false;
          _message = 'Could not remove the food — check your connection.';
        });
      case CustomFoodDeleteOutcome.deleted:
        unawaited(HapticFeedback.mediumImpact());
        widget.onItemReverted?.call(_item);
        Navigator.of(context).pop();
    }
  }

  // ---- Provenance ---------------------------------------------------------

  List<_ProvenanceChipData> get _chips {
    final source = _item.isOverride
        ? const _ProvenanceChipData(
            icon: Icons.edit_outlined,
            label: 'Edited by you',
            explanation:
                'You corrected this catalog item, so you see your own values '
                'everywhere. The original stays unchanged for everyone else — '
                'revert anytime to get it back.',
          )
        : _item.isCustom
        ? const _ProvenanceChipData(
            icon: Icons.person_outline,
            label: 'Your food',
            explanation:
                'You created this food. It is private to you and never '
                'appears in anyone else\'s search.',
          )
        : _item.source == offSource
        ? const _ProvenanceChipData(
            icon: Icons.public,
            label: 'OpenFoodFacts',
            explanation:
                'These values come from OpenFoodFacts, a community '
                'database of food labels. Spotted a mistake? Use '
                '"Edit nutrition facts" to fix it for yourself.',
          )
        : _ProvenanceChipData(
            icon: Icons.public,
            label: _item.source,
            explanation: 'Catalog food from "${_item.source}".',
          );
    return [
      source,
      if (_item.isCommunityVerified)
        const _ProvenanceChipData(
          icon: Icons.verified_outlined,
          label: 'Community verified',
          highlighted: true,
          explanation:
              'Several users independently corrected this food to the same '
              'values, so the shared entry was updated to match. Later '
              'catalog re-imports can\'t overwrite verified values.',
        ),
      if (_item.isCookedBasis)
        const _ProvenanceChipData(
          icon: Icons.outdoor_grill,
          label: 'Per 100 g cooked',
          explanation:
              'This label states nutrition per 100 g of the cooked product '
              'even though it is sold raw. When you log a raw weight, it is '
              'converted for you (~25% cooking loss).',
        ),
    ];
  }

  void _explainChip(_ProvenanceChipData chip) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(chip.label),
        content: Text(chip.explanation),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  // ---- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final totals = _totalsPer100g;
    final kcal = _item.kcal100g;

    return AppScaffold(
      safeArea: true,
      padding: EdgeInsets.zero,
      appBar: AppBar(
        title: const Text('Food details'),
        centerTitle: false,
        actions: [
          IconButton(
            onPressed: _busy ? null : _toggleFavorite,
            tooltip: _item.isFavorite
                ? 'Remove from favorites'
                : 'Add to favorites',
            icon: Icon(
              _item.isFavorite ? Icons.favorite : Icons.favorite_border,
              color: _item.isFavorite ? scheme.primary : null,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        children: [
          if (_message != null) ...[
            InlineBanner(message: _message!, tone: InlineBannerTone.error),
            const SizedBox(height: AppSpacing.md),
          ],
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: FoodImage(url: _imageUrl),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            _item.name,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          if (_item.brands.trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              _item.brands,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          Text(
            kcal == null
                ? 'Calories per 100 g unavailable'
                : '${kcal.round()} kcal per 100 g'
                      '${_item.isCookedBasis ? ' cooked' : ''}',
            style: theme.textTheme.titleSmall?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final chip in _chips)
                ActionChip(
                  avatar: Icon(
                    chip.icon,
                    size: 18,
                    color: chip.highlighted
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                  label: Text(chip.label),
                  labelStyle: theme.textTheme.labelLarge?.copyWith(
                    color: chip.highlighted ? scheme.primary : scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  backgroundColor: chip.highlighted
                      ? scheme.primary.withValues(alpha: 0.12)
                      : scheme.surfaceContainerLow,
                  side: BorderSide.none,
                  tooltip: 'What does "${chip.label}" mean?',
                  onPressed: () => _explainChip(chip),
                ),
            ],
          ),
          if (_servingRows.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < _servingRows.length; i++) ...[
                    if (i > 0)
                      Divider(height: 1, color: LuminaHealthColors.hairline),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.sm,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _servingRows[i].label,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            _servingRows[i].value,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Text(
            'NUTRITION FACTS PER 100 G'
            '${_item.isCookedBasis ? ' (COOKED)' : ''}',
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: scheme.onSurfaceVariant,
              letterSpacing: 1.5,
            ),
          ),
          NutrientBreakdownView(totals: totals, showEmptyRows: false),
          const SizedBox(height: AppSpacing.xl),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _busy ? null : _edit,
              icon: _busy
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: scheme.onPrimary,
                      ),
                    )
                  : const Icon(Icons.edit_outlined),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
              label: Text(
                'Edit nutrition facts',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: scheme.onPrimary,
                ),
              ),
            ),
          ),
          if (_item.isOverride) ...[
            const SizedBox(height: AppSpacing.xs),
            TextButton(
              onPressed: _busy ? null : _confirmRevert,
              child: Text(
                'Revert to original',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<({String label, String value})> get _servingRows {
    final rows = <({String label, String value})>[];
    final piece = _item.gramsPerPiece;
    if (piece != null && piece > 0 && _item.pieceUnit != null) {
      rows.add((
        label: '1 ${_item.pieceUnit}',
        value: '${formatAmount(piece)} g',
      ));
    }
    final serving = _item.servingSizeG;
    if (serving != null && serving > 0) {
      rows.add((label: 'Serving size', value: '${formatAmount(serving)} g'));
    }
    return rows;
  }
}

class _ProvenanceChipData {
  const _ProvenanceChipData({
    required this.icon,
    required this.label,
    required this.explanation,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final String explanation;

  /// Primary-tinted treatment for trust markers (community verified).
  final bool highlighted;
}
