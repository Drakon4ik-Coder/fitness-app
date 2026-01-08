import 'package:flutter/material.dart';

import '../../ui_components/ui_components.dart';
import '../../ui_system/tokens.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      builder: (context, scrollController) {
        return Material(
          color: theme.colorScheme.surface,
          child: Padding(
            padding: EdgeInsets.only(
              left: AppSpacing.lg,
              right: AppSpacing.lg,
              top: AppSpacing.lg,
              bottom:
                  AppSpacing.lg + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: CustomScrollView(
              controller: scrollController,
              slivers: [
                SliverToBoxAdapter(
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
                      AppTextField(
                        controller: _searchController,
                        label: 'Search foods',
                        textInputAction: TextInputAction.search,
                        suffixIcon: const Icon(Icons.search),
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
                      Text(
                        'Results',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                  ),
                ),
                SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: AppSpacing.md,
                    crossAxisSpacing: AppSpacing.md,
                    childAspectRatio: 0.95,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final item = _mockResults[index];
                      final bool isSelected = _selectedResultIndex == index;
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
    final scheme = Theme.of(context).colorScheme;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onSelected(),
      selectedColor: scheme.primaryContainer,
      side: BorderSide(
        color: scheme.outline.withOpacity(0.3),
      ),
      showCheckmark: false,
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
        ? scheme.primaryContainer.withOpacity(0.6)
        : scheme.surfaceContainerHighest;

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: onTap,
      child: Ink(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: isSelected
                ? scheme.primary.withOpacity(0.4)
                : scheme.outline.withOpacity(0.2),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 64,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(
                  item.icon,
                  color: scheme.onSurfaceVariant,
                  size: 28,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                item.name,
                style: theme.textTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '${item.kcal} kcal - ${item.serving}',
                style: theme.textTheme.bodySmall,
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
