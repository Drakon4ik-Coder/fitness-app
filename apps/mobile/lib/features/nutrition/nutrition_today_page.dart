import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui_components/ui_components.dart';
import '../../ui_system/pulse_theme.dart';
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
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.lg),
        ),
      ),
      clipBehavior: Clip.antiAlias,
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

  void _showItemDetails(BuildContext context, _MealItem item) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${item.name} details coming soon.'),
      ),
    );
  }

  List<_MacroSummary> _buildMacroSummaries(NutritionTotals? totals) {
    final carbs = totals?.carbsG.round() ?? 0;
    final fat = totals?.fatG.round() ?? 0;
    final protein = totals?.proteinG.round() ?? 0;
    return [
      _MacroSummary(
        type: MacroType.protein,
        label: 'Protein',
        current: protein,
        goal: _proteinGoalG,
      ),
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
    final scheme = theme.colorScheme;
    final effects = PulseTheme.effectsOf(context);
    final totals = _dayLog?.totals;
    final eatenKcal = totals?.kcal.round() ?? 0;
    final burnedKcal = _burnedKcal;
    final int kcalLeft = math.max(0, _dailyGoalKcal - eatenKcal + burnedKcal);
    final double ringProgress =
        math.min(1.0, eatenKcal / _dailyGoalKcal.toDouble()).toDouble();
    final macroSummaries = _buildMacroSummaries(totals);
    final mealSummaries = _buildMealSummaries(context);

    return AppScaffold(
      safeArea: false,
      padding: EdgeInsets.zero,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              scheme.background,
              scheme.surface,
              scheme.surfaceContainer,
            ],
          ),
        ),
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              if (_isLoading)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                    ),
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      color: scheme.primary,
                      backgroundColor: scheme.surfaceContainer,
                    ),
                  ),
                ),
              if (_errorMessage != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.sm,
                      AppSpacing.lg,
                      AppSpacing.sm,
                    ),
                    child: InlineBanner(
                      message: _errorMessage!,
                      tone: InlineBannerTone.error,
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    AppSpacing.md,
                  ),
                  child: Center(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final textScale =
                            MediaQuery.textScalerOf(context).scale(1.0);
                        final baseSize = 190.0;
                        final scaledSize =
                            baseSize * (1 + (textScale - 1) * 0.35);
                        final size = math.min(
                          constraints.maxWidth,
                          math.max(150.0, scaledSize),
                        );
                        return SizedBox(
                          height: size,
                          width: size,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              GlowingProgressRing(
                                progress: ringProgress,
                                size: size,
                                thickness: 12,
                                trackColor: effects.ringTrackColor,
                                progressColor: scheme.primary,
                                glowColor: scheme.primary,
                                glowLevel: PulseGlowLevel.high,
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.sm,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'Daily Calories',
                                      style:
                                          theme.textTheme.labelLarge?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        '$kcalLeft',
                                        style:
                                            theme.textTheme.displaySmall?.copyWith(
                                          color: scheme.onSurface,
                                          fontWeight: FontWeight.w700,
                                          height: 1,
                                        ),
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Remaining',
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    0,
                    AppSpacing.lg,
                    AppSpacing.md,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const double gap = AppSpacing.md;
                      final ringWidth =
                          (constraints.maxWidth - gap * 2) / 3;
                      final ringSize = math.min(110.0, ringWidth);
                      return Row(
                        children: [
                          for (int i = 0; i < macroSummaries.length; i++) ...[
                            Expanded(
                              child: Center(
                                child: MacroRing(
                                  label: macroSummaries[i].label,
                                  current: macroSummaries[i].current,
                                  goal: macroSummaries[i].goal,
                                  color: _macroAccent(macroSummaries[i].type),
                                  trackColor: effects.ringTrackColor,
                                  size: ringSize,
                                ),
                              ),
                            ),
                            if (i != macroSummaries.length - 1)
                              const SizedBox(width: gap),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Eaten Meals',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      SizedBox(
                        width: 230,
                        child: NeonPillButton(
                          onPressed: () => _openAddFoodSheet(context),
                          expand: false,
                          compact: true,
                          child: const Text(
                            '+ Add Food',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final meal = mealSummaries[index];
                    return Padding(
                      padding: EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        index == 0 ? 0 : AppSpacing.md,
                        AppSpacing.lg,
                        0,
                      ),
                      child: _MealCard(
                        meal: meal,
                        onItemTap: (item) => _showItemDetails(context, item),
                      ),
                    );
                  },
                  childCount: mealSummaries.length,
                ),
              ),
              const SliverToBoxAdapter(
                child: SizedBox(height: AppSpacing.xxl),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _macroAccent(MacroType type) {
    switch (type) {
      case MacroType.protein:
        return PulseColors.macroProtein;
      case MacroType.carbs:
        return PulseColors.macroCarbs;
      case MacroType.fat:
        return PulseColors.macroFat;
    }
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

    return GlassMealCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  meal.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
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
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
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
          if (meal.items.isEmpty)
            Text(
              'No foods logged yet.',
              style: secondaryStyle,
            )
          else
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
    final scheme = theme.colorScheme;
    final hasImage = item.image != null;
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
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
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              child: Icon(
                hasImage
                    ? Icons.image_outlined
                    : item.icon ?? Icons.restaurant,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                    ),
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
                    color: scheme.onSurface,
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
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
