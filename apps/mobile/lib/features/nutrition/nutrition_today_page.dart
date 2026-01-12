import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui_components/ui_components.dart';
import '../../ui_system/tokens.dart';
import 'add_food_sheet.dart';
import 'data/api_exceptions.dart';
import 'data/food_local_db.dart';
import 'data/foods_api_service.dart';
import 'data/nutrition_api_service.dart';
import 'data/off_client.dart';

class NutritionTodayPage extends StatefulWidget {
  const NutritionTodayPage({
    super.key,
    required this.accessToken,
    required this.onLogout,
    this.localDb,
    this.foodsApi,
    this.nutritionApi,
    this.offClient,
  });

  final String accessToken;
  final Future<void> Function() onLogout;
  final FoodLocalDb? localDb;
  final FoodsApiService? foodsApi;
  final NutritionApiService? nutritionApi;
  final OffClient? offClient;

  @override
  State<NutritionTodayPage> createState() => _NutritionTodayPageState();
}

class _NutritionTodayPageState extends State<NutritionTodayPage> {
  late DateTime _selectedDate;
  late final FoodLocalDb _localDb;
  late final bool _ownsLocalDb;
  late final FoodsApiService _foodsApi;
  late final NutritionApiService _nutritionApi;
  late final OffClient _offClient;

  NutritionDayLog? _dayLog;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateUtils.dateOnly(DateTime.now());
    _ownsLocalDb = widget.localDb == null;
    _localDb = widget.localDb ?? FoodLocalDb();
    _foodsApi =
        widget.foodsApi ?? FoodsApiService(accessToken: widget.accessToken);
    _nutritionApi = widget.nutritionApi ??
        NutritionApiService(accessToken: widget.accessToken);
    _offClient = widget.offClient ?? OffClient();
  }

  @override
  void didUpdateWidget(covariant NutritionTodayPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accessToken != widget.accessToken) {
      _foodsApi.updateToken(widget.accessToken);
      _nutritionApi.updateToken(widget.accessToken);
    }
  }

  @override
  void dispose() {
    if (_ownsLocalDb) {
      _localDb.close();
    }
    super.dispose();
  }

  Future<void> _loadDay() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final dayLog = await _nutritionApi.fetchDay(_selectedDate);
      if (!mounted) {
        return;
      }
      setState(() {
        _dayLog = dayLog;
        _isLoading = false;
      });
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await widget.onLogout();
        if (!mounted) {
          return;
        }
        setState(() {
          _isLoading = false;
        });
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = error.message;
      });
    }
  }

  Future<void> _openAddFoodSheet(BuildContext context) async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => AddFoodSheet(
        localDb: _localDb,
        foodsApi: _foodsApi,
        nutritionApi: _nutritionApi,
        offClient: _offClient,
        onLogout: widget.onLogout,
        selectedDate: _selectedDate,
      ),
    );
  }

  void _openMacroDetails(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const _MacroDetailsPage(),
      ),
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
    final today = DateUtils.dateOnly(DateTime.now());
    final nextDate =
        DateUtils.dateOnly(_selectedDate.add(Duration(days: offset)));
    if (nextDate.isAfter(today)) {
      return;
    }
    setState(() {
      _selectedDate = nextDate;
      _dayLog = null;
      _errorMessage = null;
    });
  }

  Future<void> _pickDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final DateTime? selected = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(_selectedDate.year - 5, 1, 1),
      lastDate: today,
    );

    if (selected == null || !mounted) {
      return;
    }

    setState(() {
      _selectedDate = DateUtils.dateOnly(selected);
      _dayLog = null;
      _errorMessage = null;
    });
  }

  List<_MacroSummary> _buildMacroSummaries(NutritionTotals? totals) {
    final carbs = totals?.carbsG.round() ?? 0;
    final fat = totals?.fatG.round() ?? 0;
    final protein = totals?.proteinG.round() ?? 0;
    return [
      _MacroSummary(
        type: MacroType.carbs,
        label: 'Carbs',
        current: carbs,
        goal: _carbGoalG,
      ),
      _MacroSummary(
        type: MacroType.fat,
        label: 'Fat',
        current: fat,
        goal: _fatGoalG,
      ),
      _MacroSummary(
        type: MacroType.protein,
        label: 'Protein',
        current: protein,
        goal: _proteinGoalG,
      ),
      _MacroSummary(
        type: MacroType.other,
        label: 'Other',
        current: 0,
        goal: _otherGoalG,
      ),
    ];
  }

  List<_MealSummary> _buildMealSummaries(BuildContext context) {
    final Map<String, List<NutritionEntry>> meals = _dayLog?.meals ?? {};
    final localizations = MaterialLocalizations.of(context);
    final order = <String, IconData>{
      'breakfast': Icons.breakfast_dining,
      'lunch': Icons.lunch_dining,
      'dinner': Icons.dinner_dining,
      'snacks': Icons.emoji_food_beverage,
    };
    final labels = <String, String>{
      'breakfast': 'Breakfast',
      'lunch': 'Lunch',
      'dinner': 'Dinner',
      'snacks': 'Snacks',
    };

    final summaries = <_MealSummary>[];
    for (final entry in order.entries) {
      final mealType = entry.key;
      final icon = entry.value;
      final entries = meals[mealType] ?? [];
      final items = entries
          .map(
            (mealEntry) => _MealItem(
              name: mealEntry.foodItem.name,
              kcal: mealEntry.kcal.round(),
              amount: _formatQuantity(mealEntry.quantityG),
              icon: icon,
              image: mealEntry.foodItem.imageUrl,
            ),
          )
          .toList();
      final timeLabel = entries.isEmpty
          ? 'No entries'
          : localizations.formatTimeOfDay(
              TimeOfDay.fromDateTime(entries.first.consumedAt),
            );
      summaries.add(
        _MealSummary(
          name: labels[mealType] ?? mealType,
          time: timeLabel,
          items: items,
        ),
      );
    }
    return summaries;
  }

  String _formatQuantity(double quantityG) {
    if (quantityG == quantityG.roundToDouble()) {
      return '${quantityG.toInt()} g';
    }
    return '${quantityG.toStringAsFixed(1)} g';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final today = DateUtils.dateOnly(DateTime.now());
    final bool isToday = DateUtils.isSameDay(_selectedDate, today);
    final String formattedDate = localizations.formatMediumDate(_selectedDate);
    final String dateLabel = isToday ? 'Today' : formattedDate;
    final totals = _dayLog?.totals;
    final eatenKcal = totals?.kcal.round() ?? 0;
    final burnedKcal = _burnedKcal;
    final int kcalLeft =
        math.max(0, _dailyGoalKcal - eatenKcal + burnedKcal);
    final double ringProgress =
        math.min(1.0, eatenKcal / _dailyGoalKcal.toDouble()).toDouble();
    final neutralTrack =
        theme.colorScheme.outlineVariant.withValues(alpha: 0.4);
    final macroSummaries = _buildMacroSummaries(totals);
    final mealSummaries = _buildMealSummaries(context);

    final List<Widget> mealCards = [];
    for (int i = 0; i < mealSummaries.length; i++) {
      mealCards.add(
        _MealCard(
          meal: mealSummaries[i],
          onItemTap: (item) => _showItemDetails(context, item),
        ),
      );
      if (i != mealSummaries.length - 1) {
        mealCards.add(const SizedBox(height: AppSpacing.md));
      }
    }

    return AppScaffold(
      body: ListView(
        padding: EdgeInsets.zero,
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
                onPressed: isToday ? null : () => _shiftDay(1),
                icon: const Icon(Icons.chevron_right),
              ),
              IconButton(
                tooltip: 'Reload',
                constraints:
                    const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _isLoading ? null : _loadDay,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (_isLoading) ...[
            const SizedBox(height: AppSpacing.sm),
            LinearProgressIndicator(
              minHeight: 2,
              color: theme.colorScheme.primary,
            ),
          ],
          if (_errorMessage != null) ...[
            const SizedBox(height: AppSpacing.sm),
            InlineBanner(
              message: _errorMessage!,
              tone: InlineBannerTone.error,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
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
                          value: eatenKcal,
                          helper: 'kcal',
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Column(
                          children: [
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final textScale =
                                    MediaQuery.textScalerOf(context).scale(1.0);
                                final baseSize = 150.0;
                                final scaledSize =
                                    baseSize * (1 + (textScale - 1) * 0.25);
                                final size = math.min(
                                  constraints.maxWidth,
                                  math.max(140.0, scaledSize),
                                );
                                return SizedBox(
                                  height: size,
                                  width: size,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      SizedBox.expand(
                                        child: CircularProgressIndicator(
                                          value: ringProgress,
                                          strokeWidth: 10,
                                          backgroundColor: neutralTrack,
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: AppSpacing.sm),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: Text(
                                                '$kcalLeft',
                                                style: theme
                                                    .textTheme.titleLarge
                                                    ?.copyWith(
                                                  height: 1.0,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                                textAlign: TextAlign.center,
                                                maxLines: 1,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              'kcal left',
                                              style: theme
                                                  .textTheme.bodySmall
                                                  ?.copyWith(
                                                height: 1.1,
                                                color: theme
                                                    .colorScheme.onSurfaceVariant,
                                              ),
                                              textAlign: TextAlign.center,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
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
                          value: burnedKcal,
                          helper: 'kcal',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      const double gap = AppSpacing.md;
                      final textScale =
                          MediaQuery.textScalerOf(context).scale(1.0);
                      final minTileWidth =
                          140 * math.min(textScale, 1.4);
                      int columns = 3;
                      if (constraints.maxWidth <
                          minTileWidth * 3 + gap * 2) {
                        columns = 2;
                      }
                      if (constraints.maxWidth < minTileWidth * 2 + gap) {
                        columns = 1;
                      }
                      final tileWidth = (constraints.maxWidth -
                              gap * (columns - 1)) /
                          columns;
                      return Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: [
                          for (final macro in macroSummaries)
                            SizedBox(
                              width: tileWidth,
                              child: _MacroTile(
                                macro: macro,
                                color: theme.colorScheme.primary,
                                trackColor: neutralTrack,
                                onTap: macro.type == MacroType.other
                                    ? () => _openMacroDetails(context)
                                    : null,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          const AppSection(title: 'Meals'),
          const SizedBox(height: AppSpacing.sm),
          ...mealCards,
          const SizedBox(height: AppSpacing.lg),
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
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final valueStyle = theme.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w600,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: secondaryStyle,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '$value',
          style: valueStyle,
          textAlign: TextAlign.center,
        ),
        Text(
          helper,
          style: secondaryStyle,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _MacroTile extends StatelessWidget {
  const _MacroTile({
    required this.macro,
    required this.color,
    required this.trackColor,
    this.onTap,
  });

  final _MacroSummary macro;
  final Color color;
  final Color trackColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = math.min(1.0, macro.current / macro.goal).toDouble();

    final label = Row(
      children: [
        Expanded(
          child: Text(
            macro.label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (onTap != null) ...[
          const SizedBox(width: AppSpacing.xs),
          Icon(
            Icons.chevron_right,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ],
      ],
    );

    final content = Padding(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label,
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${macro.current} / ${macro.goal} g',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 5,
              color: color,
              backgroundColor: trackColor,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) {
      return content;
    }

    return Semantics(
      button: true,
      label: 'View all macros',
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: content,
      ),
    );
  }
}

class _MacroDetailsPage extends StatelessWidget {
  const _MacroDetailsPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppScaffold(
      appBar: AppBar(
        title: const Text('Macros'),
      ),
      scrollable: true,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Macro details coming soon.',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'This page will show all macro progress bars.',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
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
    final dividerColor = theme.dividerTheme.color ??
        theme.colorScheme.outlineVariant.withValues(alpha: 0.4);
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

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
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      meal.time,
                      style: secondaryStyle,
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
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

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
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
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
                    style: secondaryStyle,
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
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
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
const int _burnedKcal = 0;
const int _carbGoalG = 260;
const int _fatGoalG = 70;
const int _proteinGoalG = 150;
const int _otherGoalG = 100;

enum MacroType { carbs, fat, protein, other }

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
