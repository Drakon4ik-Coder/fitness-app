import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui_components/ui_components.dart';
import '../../ui_system/tokens.dart';
import 'add_food_sheet.dart';

class NutritionTodayPage extends StatefulWidget {
  const NutritionTodayPage({super.key});

  @override
  State<NutritionTodayPage> createState() => _NutritionTodayPageState();
}

class _NutritionTodayPageState extends State<NutritionTodayPage> {
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateUtils.dateOnly(DateTime.now());
  }

  void _openAddFoodSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => const AddFoodSheet(),
    );
  }

  void _showItemDetails(BuildContext context, _MealItem item) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${item.name} details coming soon.'),
      ),
    );
  }

  void _shiftDay(int offset) {
    setState(() {
      _selectedDate =
          DateUtils.dateOnly(_selectedDate.add(Duration(days: offset)));
    });
  }

  Future<void> _pickDate() async {
    final DateTime? selected = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(_selectedDate.year - 5, 1, 1),
      lastDate: DateTime(_selectedDate.year + 5, 12, 31),
    );

    if (selected == null || !mounted) {
      return;
    }

    setState(() {
      _selectedDate = DateUtils.dateOnly(selected);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final today = DateUtils.dateOnly(DateTime.now());
    final bool isToday = DateUtils.isSameDay(_selectedDate, today);
    final String formattedDate = localizations.formatMediumDate(_selectedDate);
    final String dateLabel = isToday ? 'Today' : formattedDate;
    final int kcalLeft = math.max(0, _dailyGoalKcal - _eatenKcal + _burnedKcal);
    final double ringProgress =
        math.min(1.0, _eatenKcal / _dailyGoalKcal.toDouble()).toDouble();

    return AppScaffold(
      scrollable: true,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Previous day',
                constraints:
                    const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => _shiftDay(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Semantics(
                  button: true,
                  label: 'Select date',
                  value: isToday ? 'Today, $formattedDate' : formattedDate,
                  child: TextButton(
                    onPressed: _pickDate,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          dateLabel,
                          style: theme.textTheme.titleMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                        if (isToday) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            formattedDate,
                            style: theme.textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Next day',
                constraints:
                    const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => _shiftDay(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _SummaryStat(
                          label: 'Eaten',
                          value: _eatenKcal,
                          helper: 'kcal',
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Column(
                          children: [
                            SizedBox(
                              height: 96,
                              width: 96,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  CircularProgressIndicator(
                                    value: ringProgress,
                                    strokeWidth: 10,
                                    backgroundColor: theme
                                        .colorScheme.surfaceContainerHighest,
                                  ),
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '$kcalLeft',
                                        style: theme.textTheme.titleLarge,
                                      ),
                                      Text(
                                        'kcal left',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            SizedBox(
                              width: double.infinity,
                              child: AppPrimaryButton(
                                onPressed: () => _openAddFoodSheet(context),
                                child: const Text('+ Add food'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: _SummaryStat(
                          label: 'Burned',
                          value: _burnedKcal,
                          helper: 'kcal',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Macros',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  for (int i = 0; i < _macroSummaries.length; i++) ...[
                    _MacroRow(macro: _macroSummaries[i]),
                    if (i != _macroSummaries.length - 1)
                      const SizedBox(height: AppSpacing.md),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSection(
            title: 'Meals',
            child: Column(
              children: [
                for (int i = 0; i < _mealSummaries.length; i++) ...[
                  _MealCard(
                    meal: _mealSummaries[i],
                    onItemTap: (item) => _showItemDetails(context, item),
                  ),
                  if (i != _mealSummaries.length - 1)
                    const SizedBox(height: AppSpacing.md),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({
    required this.label,
    required this.value,
    required this.helper,
  });

  final String label;
  final int value;
  final String helper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '$value',
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        Text(
          helper,
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _MacroRow extends StatelessWidget {
  const _MacroRow({required this.macro});

  final _MacroSummary macro;

  Color _macroColor(ThemeData theme, MacroType type) {
    final scheme = theme.colorScheme;
    switch (type) {
      case MacroType.carbs:
        return scheme.tertiary;
      case MacroType.fat:
        return scheme.secondary;
      case MacroType.protein:
        return scheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = math.min(1.0, macro.current / macro.goal).toDouble();
    final color = _macroColor(theme, macro.type);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                macro.label,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '${macro.current} / ${macro.goal} g',
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            color: color,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }
}

class _MealCard extends StatelessWidget {
  const _MealCard({
    required this.meal,
    required this.onItemTap,
  });

  final _MealSummary meal;
  final ValueChanged<_MealItem> onItemTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dividerColor = theme.colorScheme.outlineVariant.withOpacity(0.5);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    meal.name,
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${meal.totalKcal} kcal',
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      meal.time,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            for (int i = 0; i < meal.items.length; i++) ...[
              _MealItemRow(
                item: meal.items[i],
                onTap: () => onItemTap(meal.items[i]),
              ),
              if (i != meal.items.length - 1)
                Divider(height: AppSpacing.lg, color: dividerColor),
            ],
          ],
        ),
      ),
    );
  }
}

class _MealItemRow extends StatelessWidget {
  const _MealItemRow({required this.item, required this.onTap});

  final _MealItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasImage = item.image != null;

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: [
            Container(
              height: 44,
              width: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(
                hasImage
                    ? Icons.image_outlined
                    : item.icon ?? Icons.restaurant,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    item.amount,
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${item.kcal} kcal',
                  style: theme.textTheme.bodyMedium,
                ),
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

const int _dailyGoalKcal = 2200;
const int _eatenKcal = 1450;
const int _burnedKcal = 320;

enum MacroType { carbs, fat, protein }

class _MacroSummary {
  const _MacroSummary({
    required this.type,
    required this.label,
    required this.current,
    required this.goal,
  });

  final MacroType type;
  final String label;
  final int current;
  final int goal;
}

class _MealItem {
  const _MealItem({
    required this.name,
    required this.kcal,
    required this.amount,
    this.icon,
    this.image,
  });

  final String name;
  final int kcal;
  final String amount;
  final IconData? icon;
  final String? image;
}

class _MealSummary {
  const _MealSummary({
    required this.name,
    required this.time,
    required this.items,
  });

  final String name;
  final String time;
  final List<_MealItem> items;

  int get totalKcal =>
      items.fold<int>(0, (total, item) => total + item.kcal);
}

const List<_MacroSummary> _macroSummaries = [
  _MacroSummary(
    type: MacroType.carbs,
    label: 'Carbs',
    current: 180,
    goal: 260,
  ),
  _MacroSummary(
    type: MacroType.fat,
    label: 'Fat',
    current: 62,
    goal: 70,
  ),
  _MacroSummary(
    type: MacroType.protein,
    label: 'Protein',
    current: 110,
    goal: 150,
  ),
];

const List<_MealSummary> _mealSummaries = [
  _MealSummary(
    name: 'Breakfast',
    time: '8:10 AM',
    items: [
      _MealItem(
        name: 'Greek yogurt',
        kcal: 180,
        amount: '200 g',
        icon: Icons.breakfast_dining,
        image: 'assets/foods/yogurt.png',
      ),
      _MealItem(
        name: 'Blueberries',
        kcal: 85,
        amount: '120 g',
        icon: Icons.local_grocery_store,
      ),
    ],
  ),
  _MealSummary(
    name: 'Lunch',
    time: '12:35 PM',
    items: [
      _MealItem(
        name: 'Chicken salad wrap',
        kcal: 420,
        amount: '1 wrap',
        icon: Icons.lunch_dining,
        image: 'assets/foods/wrap.png',
      ),
      _MealItem(
        name: 'Sparkling water',
        kcal: 0,
        amount: '330 ml',
        icon: Icons.local_drink,
      ),
    ],
  ),
  _MealSummary(
    name: 'Dinner',
    time: '7:05 PM',
    items: [
      _MealItem(
        name: 'Salmon bowl',
        kcal: 520,
        amount: '1 bowl',
        icon: Icons.dinner_dining,
        image: 'assets/foods/salmon.png',
      ),
      _MealItem(
        name: 'Roasted veggies',
        kcal: 160,
        amount: '180 g',
        icon: Icons.eco_outlined,
      ),
    ],
  ),
  _MealSummary(
    name: 'Snacks',
    time: '4:20 PM',
    items: [
      _MealItem(
        name: 'Protein bar',
        kcal: 220,
        amount: '1 bar',
        icon: Icons.emoji_food_beverage,
      ),
      _MealItem(
        name: 'Iced latte',
        kcal: 140,
        amount: '12 oz',
        icon: Icons.local_cafe,
      ),
    ],
  ),
];
