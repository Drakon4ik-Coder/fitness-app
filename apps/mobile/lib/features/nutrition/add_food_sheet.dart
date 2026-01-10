import 'package:flutter/material.dart';

import '../../ui_system/tokens.dart';
import 'nutrition_scan_page.dart';

class AddFoodSheet extends StatefulWidget {
  const AddFoodSheet({super.key});

  @override
  State<AddFoodSheet> createState() => _AddFoodSheetState();
}

class _AddFoodSheetState extends State<AddFoodSheet> {
  final TextEditingController _searchController = TextEditingController();
  MealType _selectedMeal = MealType.breakfast;
  String _selectedFilter = 'Recent';
  int? _selectedResultIndex;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _selectMeal(MealType meal) {
    setState(() {
      _selectedMeal = meal;
    });
  }

  void _selectFilter(String filter) {
    setState(() {
      _selectedFilter = filter;
    });
  }

  void _selectResult(int index) {
    setState(() {
      _selectedResultIndex = index;
    });
  }

  void _openScanPage() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const NutritionScanPage(),
      ),
    );
  }

  String _resultsHeading(String query) {
    final trimmed = query.trim();
    if (trimmed.isNotEmpty) {
      return 'Search results';
    }
    if (_selectedFilter == 'Favorites') {
      return 'Favorites';
    }
    return 'Recent foods';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      builder: (context, scrollController) {
        return Material(
          color: scheme.surface,
          child: Padding(
            padding: EdgeInsets.only(
              left: AppSpacing.lg,
              right: AppSpacing.lg,
              top: AppSpacing.lg,
              bottom:
                  AppSpacing.lg + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add food',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Choose meal',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<MealType>(
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      backgroundColor: MaterialStateProperty.resolveWith(
                        (states) => states.contains(MaterialState.selected)
                            ? scheme.primaryContainer
                            : scheme.surfaceContainer,
                      ),
                      foregroundColor: MaterialStateProperty.resolveWith(
                        (states) => states.contains(MaterialState.selected)
                            ? scheme.onPrimaryContainer
                            : scheme.onSurface,
                      ),
                      side: MaterialStateProperty.all(
                        BorderSide(color: scheme.outlineVariant),
                      ),
                    ),
                    segments: const [
                      ButtonSegment(
                        value: MealType.breakfast,
                        label: Text('Breakfast'),
                      ),
                      ButtonSegment(
                        value: MealType.lunch,
                        label: Text('Lunch'),
                      ),
                      ButtonSegment(
                        value: MealType.dinner,
                        label: Text('Dinner'),
                      ),
                      ButtonSegment(
                        value: MealType.snacks,
                        label: Text('Snacks'),
                      ),
                    ],
                    selected: {_selectedMeal},
                    onSelectionChanged: (selection) {
                      if (selection.isEmpty) {
                        return;
                      }
                      _selectMeal(selection.first);
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                _SearchBarGroup(
                  controller: _searchController,
                  onScan: _openScanPage,
                ),
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    _FilterChip(
                      label: 'Recent',
                      isSelected: _selectedFilter == 'Recent',
                      onSelected: () => _selectFilter('Recent'),
                    ),
                    _FilterChip(
                      label: 'Favorites',
                      isSelected: _selectedFilter == 'Favorites',
                      onSelected: () => _selectFilter('Favorites'),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                Expanded(
                  child: CustomScrollView(
                    controller: scrollController,
                    slivers: [
                      SliverToBoxAdapter(
                        child: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _searchController,
                          builder: (context, value, _) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _resultsHeading(value.text),
                                  style: theme.textTheme.titleSmall,
                                ),
                                const SizedBox(height: AppSpacing.sm),
                              ],
                            );
                          },
                        ),
                      ),
                      SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: AppSpacing.sm,
                          crossAxisSpacing: AppSpacing.sm,
                          childAspectRatio: 1.2,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final item = _mockResults[index];
                            final bool isSelected =
                                _selectedResultIndex == index;
                            return _FoodResultTile(
                              item: item,
                              isSelected: isSelected,
                              onTap: () => _selectResult(index),
                            );
                          },
                          childCount: _mockResults.length,
                        ),
                      ),
                      const SliverToBoxAdapter(
                        child: SizedBox(height: AppSpacing.xl),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.isSelected,
    required this.onSelected,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final labelColor =
        isSelected ? scheme.onPrimaryContainer : scheme.onSurface;
    return FilterChip(
      label: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(color: labelColor),
      ),
      selected: isSelected,
      onSelected: (_) => onSelected(),
      selectedColor: scheme.primaryContainer,
      backgroundColor: scheme.surfaceContainer,
      side: BorderSide(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
      ),
      showCheckmark: false,
    );
  }
}

class _SearchBarGroup extends StatelessWidget {
  const _SearchBarGroup({
    required this.controller,
    required this.onScan,
  });

  final TextEditingController controller;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: IconButton(
                tooltip: 'Scan barcode',
                onPressed: onScan,
                style: IconButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                ),
                icon: const Icon(Icons.qr_code_scanner),
              ),
            ),
            Container(
              width: 1,
              height: 32,
              color: scheme.outlineVariant.withValues(alpha: 0.7),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  labelText: 'Search foods',
                  floatingLabelBehavior: FloatingLabelBehavior.never,
                  border: InputBorder.none,
                  isDense: true,
                  filled: false,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final hasText = value.text.trim().isNotEmpty;
                if (hasText) {
                  return SizedBox(
                    width: 48,
                    child: IconButton(
                      tooltip: 'Clear search',
                      onPressed: controller.clear,
                      style: IconButton.styleFrom(
                        foregroundColor: scheme.onSurfaceVariant,
                      ),
                      icon: const Icon(Icons.close),
                    ),
                  );
                }
                return SizedBox(
                  width: 48,
                  child: Center(
                    child: Icon(
                      Icons.search,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _FoodResultTile extends StatelessWidget {
  const _FoodResultTile({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  final _FoodResult item;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background = isSelected
        ? scheme.primaryContainer
        : scheme.surfaceContainerHigh;
    final contentColor =
        isSelected ? scheme.onPrimaryContainer : scheme.onSurface;
    final metaColor = isSelected
        ? scheme.onPrimaryContainer.withValues(alpha: 0.75)
        : scheme.onSurfaceVariant;
    final mediaColor = isSelected
        ? scheme.surfaceContainerLowest
        : scheme.surfaceContainerLow;

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: onTap,
      child: Ink(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: isSelected
                ? scheme.outlineVariant.withValues(alpha: 0.8)
                : scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 48,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: mediaColor,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(
                  item.icon,
                  color: contentColor,
                  size: 24,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                item.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: contentColor,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '${item.kcal} kcal - ${item.serving}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: metaColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum MealType { breakfast, lunch, dinner, snacks }

class _FoodResult {
  const _FoodResult({
    required this.name,
    required this.kcal,
    required this.serving,
    required this.icon,
  });

  final String name;
  final int kcal;
  final String serving;
  final IconData icon;
}

const List<_FoodResult> _mockResults = [
  _FoodResult(
    name: 'Overnight oats',
    kcal: 280,
    serving: '1 jar',
    icon: Icons.ramen_dining,
  ),
  _FoodResult(
    name: 'Avocado toast',
    kcal: 320,
    serving: '2 slices',
    icon: Icons.breakfast_dining,
  ),
  _FoodResult(
    name: 'Turkey chili',
    kcal: 410,
    serving: '1 bowl',
    icon: Icons.soup_kitchen,
  ),
  _FoodResult(
    name: 'Poke bowl',
    kcal: 540,
    serving: '1 bowl',
    icon: Icons.rice_bowl,
  ),
  _FoodResult(
    name: 'Matcha latte',
    kcal: 160,
    serving: '12 oz',
    icon: Icons.local_cafe,
  ),
  _FoodResult(
    name: 'Trail mix',
    kcal: 210,
    serving: '1 pack',
    icon: Icons.emoji_food_beverage,
  ),
];
