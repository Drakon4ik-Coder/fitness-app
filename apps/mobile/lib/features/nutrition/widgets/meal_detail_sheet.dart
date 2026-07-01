import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../../ui_system/tokens.dart';
import '../data/nutrient_catalog.dart';
import '../data/nutrition_api_service.dart';
import 'amount_sheet.dart';
import 'nutrient_breakdown_view.dart';

/// Bottom sheet that opens when a logged meal is tapped. Lists every food in the
/// meal and lets the user change an item's amount (reusing the add-food
/// [AmountSheet]) or remove it. Keeps a local copy of the entries so edits/
/// deletes reflect immediately; the parent reloads the day after dismissal to
/// refresh the calorie ring and macro bars.
class MealDetailSheet extends StatefulWidget {
  const MealDetailSheet({
    super.key,
    required this.mealLabel,
    required this.mealIcon,
    required this.entries,
    required this.onUpdateQuantity,
    required this.onDeleteEntry,
    required this.onAddMore,
  });

  final String mealLabel;
  final IconData mealIcon;
  final List<NutritionEntry> entries;

  /// Persists a new amount for [entry]. Returns the updated entry on success, or
  /// null if the request failed.
  final Future<NutritionEntry?> Function(NutritionEntry entry, double grams)
  onUpdateQuantity;

  /// Removes [entry] from the log. Returns true on success.
  final Future<bool> Function(NutritionEntry entry) onDeleteEntry;

  /// Closes the sheet and opens add-food scoped to this meal.
  final VoidCallback onAddMore;

  @override
  State<MealDetailSheet> createState() => _MealDetailSheetState();
}

class _MealDetailSheetState extends State<MealDetailSheet> {
  late final List<NutritionEntry> _entries;
  int? _busyEntryId;

  @override
  void initState() {
    super.initState();
    _entries = List.of(widget.entries);
  }

  int get _totalKcal => _entries.fold<int>(0, (sum, e) => sum + e.kcal.round());

  Future<void> _editAmount(NutritionEntry entry) async {
    final result = await showAmountSheet(
      context: context,
      item: entry.foodItem,
      initialGrams: entry.quantityG,
      isEditing: true,
    );
    if (result == null || !mounted) return;
    if (result.removed) {
      await _delete(entry, confirm: false);
      return;
    }
    final grams = result.grams;
    if (grams == null || grams == entry.quantityG) return;
    setState(() => _busyEntryId = entry.id);
    final updated = await widget.onUpdateQuantity(entry, grams);
    if (!mounted) return;
    setState(() {
      _busyEntryId = null;
      if (updated != null) {
        final index = _entries.indexWhere((e) => e.id == entry.id);
        if (index != -1) _entries[index] = updated;
      }
    });
  }

  Future<void> _delete(NutritionEntry entry, {bool confirm = true}) async {
    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove food?'),
          content: Text(
            'Remove ${entry.foodItem.name} from ${widget.mealLabel.toLowerCase()}?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error,
              ),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _busyEntryId = entry.id);
    final success = await widget.onDeleteEntry(entry);
    if (!mounted) return;
    setState(() {
      _busyEntryId = null;
      if (success) {
        _entries.removeWhere((e) => e.id == entry.id);
      }
    });
    if (success) HapticFeedback.mediumImpact();
    if (_entries.isEmpty && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
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
              _Header(
                icon: widget.mealIcon,
                label: widget.mealLabel,
                totalKcal: _totalKcal,
                itemCount: _entries.length,
              ),
              Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
              Expanded(
                child: _entries.isEmpty
                    ? _EmptyState(scrollController: scrollController)
                    : ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.sm,
                        ),
                        itemCount: _entries.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          indent: AppSpacing.lg,
                          endIndent: AppSpacing.lg,
                          color: scheme.outlineVariant.withValues(alpha: 0.25),
                        ),
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          return _EntryRow(
                            entry: entry,
                            busy: _busyEntryId == entry.id,
                            onEdit: () => _editAmount(entry),
                            onDelete: () => _delete(entry),
                          );
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.sm,
                    AppSpacing.lg,
                    AppSpacing.md,
                  ),
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: widget.onAddMore,
                      icon: const Icon(Icons.add),
                      label: Text('Add to ${widget.mealLabel.toLowerCase()}'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.primary,
                        side: BorderSide(
                          color: scheme.primary.withValues(alpha: 0.5),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                      ),
                    ),
                  ),
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
  const _Header({
    required this.icon,
    required this.label,
    required this.totalKcal,
    required this.itemCount,
  });

  final IconData icon;
  final String label;
  final int totalKcal;
  final int itemCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final itemLabel = itemCount == 1 ? '1 item' : '$itemCount items';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(icon, color: scheme.primary),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  itemLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$totalKcal',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: scheme.primary,
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

class _EntryRow extends StatefulWidget {
  const _EntryRow({
    required this.entry,
    required this.busy,
    required this.onEdit,
    required this.onDelete,
  });

  final NutritionEntry entry;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entry = widget.entry;
    final imageUrl = entry.foodItem.imageUrl?.trim();
    // Per-food breakdown scaled to this entry's logged amount. Data-only (no
    // "no data" rows) keeps the inline expansion compact.
    final totals = aggregateNutrients([entry]);

    return Column(
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                FoodThumb(
                  url: (imageUrl != null && imageUrl.isNotEmpty)
                      ? imageUrl
                      : null,
                  size: 44,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.foodItem.name,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              '${describeAmount(entry.quantityG, entry.foodItem)}  •  ${entry.kcal.round()} kcal',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          AnimatedRotation(
                            turns: _expanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: Icon(
                              Icons.expand_more,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (widget.busy)
                  const Padding(
                    padding: EdgeInsets.all(AppSpacing.sm),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                else ...[
                  IconButton(
                    onPressed: widget.onEdit,
                    icon: const Icon(Icons.edit_outlined),
                    iconSize: 20,
                    tooltip: 'Edit amount',
                    color: scheme.onSurfaceVariant,
                  ),
                  IconButton(
                    onPressed: widget.onDelete,
                    icon: const Icon(Icons.delete_outline),
                    iconSize: 20,
                    tooltip: 'Remove',
                    color: scheme.error,
                  ),
                ],
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    0,
                    AppSpacing.lg,
                    AppSpacing.sm,
                  ),
                  child: NutrientBreakdownView(
                    totals: totals,
                    showEmptyRows: false,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      controller: scrollController,
      children: [
        const SizedBox(height: AppSpacing.xxl),
        Icon(
          Icons.no_meals,
          size: 40,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'No foods logged yet.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
