import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../../ui_system/tokens.dart';
import '../data/food_models.dart';
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
    required this.mealTypeName,
    required this.mealIcon,
    required this.entries,
    required this.onUpdateEntry,
    required this.onDeleteEntry,
    required this.onAddMore,
    this.focusSpecs,
    this.onViewFoodDetails,
  });

  final String mealLabel;

  /// The backend `meal_type` name for this meal ('breakfast'/…), used to exclude
  /// it from the "Move all to…" target list.
  final String mealTypeName;
  final IconData mealIcon;
  final List<NutritionEntry> entries;

  /// Persists a new amount and/or meal type for [entry]. Returns the updated
  /// entry on success, or null if the request failed.
  final Future<NutritionEntry?> Function(
    NutritionEntry entry, {
    double? quantityG,
    String? mealType,
  })
  onUpdateEntry;

  /// Removes [entry] from the log. Returns true on success.
  final Future<bool> Function(NutritionEntry entry) onDeleteEntry;

  /// Closes the sheet and opens add-food scoped to this meal.
  final VoidCallback onAddMore;

  /// The user's focus nutrients, forwarded to the amount sheet so its preview
  /// pills match the today page. Null falls back to the default trio.
  final List<NutrientSpec>? focusSpecs;

  /// Opens the food detail page (KAN-33) for a logged food, resolving with
  /// the updated item when it was edited there (null = unchanged). Enables
  /// the "Food details" link in each expanded row and the amount sheet's
  /// header tap; null hides both.
  final Future<FoodItem?> Function(FoodItem item)? onViewFoodDetails;

  @override
  State<MealDetailSheet> createState() => _MealDetailSheetState();
}

class _MealDetailSheetState extends State<MealDetailSheet> {
  late final List<NutritionEntry> _entries;
  int? _busyEntryId;
  bool _movingAll = false;

  @override
  void initState() {
    super.initState();
    _entries = List.of(widget.entries);
  }

  int get _totalKcal => _entries.fold<int>(0, (sum, e) => sum + e.kcal.round());

  bool get _busy => _busyEntryId != null || _movingAll;

  /// Prompts for a target meal, then moves every food in this meal to it. On
  /// full success the meal is now empty, so the sheet closes; the parent reloads
  /// the day. Partial failures keep the un-moved foods and surface a message.
  Future<void> _moveAll() async {
    final target = await _pickTargetMeal();
    if (target == null || !mounted || _entries.isEmpty) return;
    setState(() => _movingAll = true);
    final moved = <NutritionEntry>[];
    for (final entry in List.of(_entries)) {
      final updated = await widget.onUpdateEntry(entry, mealType: target);
      if (updated != null) moved.add(entry);
      if (!mounted) return;
    }
    setState(() {
      _movingAll = false;
      _entries.removeWhere(moved.contains);
    });
    if (moved.isNotEmpty) HapticFeedback.mediumImpact();
    if (_entries.isEmpty && mounted) {
      Navigator.of(context).pop();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Some foods could not be moved.')),
      );
    }
  }

  /// A bottom sheet listing the meals other than this one; resolves to the chosen
  /// `meal_type` name, or null if dismissed.
  Future<String?> _pickTargetMeal() {
    final targets = kMealTypeOptions
        .where((o) => o.name != widget.mealTypeName)
        .toList();
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text(
                  'Move all to…',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
              for (final option in targets)
                ListTile(
                  leading: Icon(option.icon, color: scheme.primary),
                  title: Text(option.label),
                  onTap: () => Navigator.of(ctx).pop(option.name),
                ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),
        );
      },
    );
  }

  Future<void> _editAmount(NutritionEntry entry) async {
    final result = await showAmountSheet(
      context: context,
      item: entry.foodItem,
      initialGrams: entry.quantityG,
      isEditing: true,
      initialMealType: entry.mealType,
      focusSpecs: widget.focusSpecs,
      onViewDetails: widget.onViewFoodDetails,
    );
    if (result == null || !mounted) return;
    if (result.removed) {
      await _delete(entry, confirm: false);
      return;
    }
    final grams = result.grams;
    final mealType = result.mealType;
    final gramsChanged = grams != null && grams != entry.quantityG;
    final mealChanged = mealType != null && mealType != entry.mealType;
    if (!gramsChanged && !mealChanged) return;
    setState(() => _busyEntryId = entry.id);
    final updated = await widget.onUpdateEntry(
      entry,
      quantityG: gramsChanged ? grams : null,
      mealType: mealChanged ? mealType : null,
    );
    if (!mounted) return;
    setState(() {
      _busyEntryId = null;
      if (updated != null) {
        final index = _entries.indexWhere((e) => e.id == entry.id);
        if (index != -1) {
          // Moving to another meal drops it from this meal's list; a plain
          // amount edit updates it in place.
          if (mealChanged) {
            _entries.removeAt(index);
          } else {
            _entries[index] = updated;
          }
        }
      }
    });
    if (mealChanged && updated != null) HapticFeedback.selectionClick();
    if (_entries.isEmpty && mounted) {
      Navigator.of(context).pop();
    }
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
                moving: _movingAll,
                onMoveAll: _busy || _entries.isEmpty ? null : _moveAll,
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
                            busy: _busyEntryId == entry.id || _movingAll,
                            onEdit: () => _editAmount(entry),
                            onDelete: () => _delete(entry),
                            onViewDetails: widget.onViewFoodDetails == null
                                ? null
                                : () =>
                                    widget.onViewFoodDetails!(entry.foodItem),
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
    required this.moving,
    required this.onMoveAll,
  });

  final IconData icon;
  final String label;
  final int totalKcal;
  final int itemCount;
  final bool moving;

  /// Opens the "move all to…" flow; null disables the action (e.g. mid-move).
  final VoidCallback? onMoveAll;

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
          if (moving)
            const Padding(
              padding: EdgeInsets.only(left: AppSpacing.sm),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            )
          else
            IconButton(
              onPressed: onMoveAll,
              icon: const Icon(Icons.drive_file_move_outline),
              iconSize: 22,
              tooltip: 'Move all to another meal',
              color: scheme.onSurfaceVariant,
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
    this.onViewDetails,
  });

  final NutritionEntry entry;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// Opens the food detail page for this entry's food. Shown as a "Food
  /// details" link inside the expanded breakdown; null hides the link.
  final Future<void> Function()? onViewDetails;

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
                  child: Column(
                    children: [
                      NutrientBreakdownView(
                        totals: totals,
                        showEmptyRows: false,
                      ),
                      // Entry point to the read-first food page (KAN-33):
                      // full per-100g facts, provenance, and the visible
                      // "Edit nutrition facts" action.
                      if (widget.onViewDetails != null)
                        InkWell(
                          onTap: widget.onViewDetails,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: AppSpacing.sm,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'Food details',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.xs),
                                Icon(
                                  Icons.chevron_right,
                                  size: 18,
                                  color: scheme.primary,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
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
