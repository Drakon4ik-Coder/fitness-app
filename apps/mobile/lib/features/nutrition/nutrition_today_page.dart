import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui_components/ui_components.dart';
import '../../ui_system/lumina_health_theme.dart';
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
    _loadDay();
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
    final didAdd = await showModalBottomSheet<bool>(
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
    if (!mounted || didAdd != true) {
      return;
    }
    await _loadDay();
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
    final totals = _dayLog?.totals;
    final eatenKcal = totals?.kcal.round() ?? 0;
    final burnedKcal = _burnedKcal;
    final int kcalLeft = math.max(0, _dailyGoalKcal - eatenKcal + burnedKcal);
    final double ringProgress =
        math.min(1.0, eatenKcal / _dailyGoalKcal.toDouble()).toDouble();
    final macroSummaries = _buildMacroSummaries(totals);
    final mealSummaries = _buildMealSummaries(context);

    // Calculate total entries
    final totalEntries = _dayLog?.meals.values
            .fold<int>(0, (sum, list) => sum + list.length) ??
        0;

    return AppScaffold(
      safeArea: false,
      padding: EdgeInsets.zero,
      body: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
        ),
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.sizeOf(context).height * 0.6,
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.topCenter,
                    radius: 1.0,
                    colors: [
                      LuminaHealthColors.primary.withValues(alpha: 0.08),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.65],
                  ),
                ),
              ),
            ),
            SafeArea(
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
                  // Top Header
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.chevron_left),
                            color: LuminaHealthColors.primary,
                            onPressed: () {},
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'SYMBIO',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: LuminaHealthColors.primary
                                      .withValues(alpha: 0.6),
                                  letterSpacing: 2.0,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 10,
                                ),
                              ),
                              Text(
                                'Today',
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: LuminaHealthColors.primary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.chevron_right),
                            color: LuminaHealthColors.primary,
                            onPressed: () {},
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Hero Biometric Section
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                      child: Column(
                        children: [
                          // Central ring
                          SizedBox(
                            height: 288,
                            width: 288,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                GlowingProgressRing(
                                  progress: ringProgress,
                                  size: 288,
                                  thickness: 12,
                                  trackColor: scheme.surfaceContainerHighest
                                      .withValues(alpha: 0.5),
                                  progressColor: scheme.primary,
                                  glowColor: scheme.primary,
                                  glowLevel: PulseGlowLevel.high,
                                ),
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '$kcalLeft',
                                      style: theme.textTheme.displayLarge
                                          ?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        height: 1,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'LEFT',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 2.0,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    IconButton(
                                      onPressed: () =>
                                          _openAddFoodSheet(context),
                                      icon: const Icon(Icons.add),
                                      style: IconButton.styleFrom(
                                        backgroundColor: scheme.primary
                                            .withValues(alpha: 0.1),
                                        foregroundColor: scheme.primary,
                                        side: BorderSide(
                                          color: scheme.primary
                                              .withValues(alpha: 0.2),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xl),
                          // Kinetic Stats Grid
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'EATEN',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 2.0,
                                        color: scheme.onSurfaceVariant,
                                        fontSize: 10,
                                      ),
                                    ),
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.baseline,
                                      textBaseline: TextBaseline.alphabetic,
                                      children: [
                                        Text(
                                          '$eatenKcal',
                                          style: theme.textTheme.headlineLarge
                                              ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: scheme.primary,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          'kcal',
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      'BURNED',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 2.0,
                                        color: scheme.onSurfaceVariant,
                                        fontSize: 10,
                                      ),
                                    ),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.baseline,
                                      textBaseline: TextBaseline.alphabetic,
                                      children: [
                                        Text(
                                          '$burnedKcal',
                                          style: theme.textTheme.headlineLarge
                                              ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: LuminaHealthColors.tertiary,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          'kcal',
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Macro Breakdown
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                      child: Container(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.05)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.white.withValues(alpha: 0.05),
                              offset: const Offset(0, 2),
                              blurRadius: 4,
                              spreadRadius: 0,
                              blurStyle: BlurStyle.inner,
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Row(
                          children: macroSummaries.map((macro) {
                            final color = _macroAccent(macro.type);
                            final progress = macro.goal > 0
                                ? (macro.current / macro.goal).clamp(0.0, 1.0)
                                : 0.0;
                            final left =
                                math.max(0, macro.goal - macro.current);
                            return Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(
                                  left: macro == macroSummaries.first
                                      ? 0
                                      : AppSpacing.sm,
                                  right: macro == macroSummaries.last
                                      ? 0
                                      : AppSpacing.sm,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          macro.label.toUpperCase(),
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: scheme.onSurfaceVariant,
                                            letterSpacing: -0.5,
                                            fontSize: 10,
                                          ),
                                        ),
                                        Text(
                                          '${macro.current}g',
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: color,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: AppSpacing.xs),
                                    LinearProgressIndicator(
                                      value: progress.toDouble(),
                                      backgroundColor:
                                          scheme.surfaceContainerHighest,
                                      color: color,
                                      minHeight: 6,
                                      borderRadius:
                                          BorderRadius.circular(9999),
                                    ),
                                    const SizedBox(height: AppSpacing.xs),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: Text(
                                        '${left}g left',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                          color: scheme.onSurface
                                              .withValues(alpha: 0.6),
                                          fontSize: 10,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
                  // Daily Logs Header
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                          AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'Daily Logs',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: scheme.onSurface,
                            ),
                          ),
                          Text(
                            '$totalEntries entries',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
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
                            onItemTap: (item) =>
                                _showItemDetails(context, item),
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
          ],
        ),
      ),
    );
  }

  Color _macroAccent(MacroType type) {
    switch (type) {
      case MacroType.protein:
        return LuminaHealthColors.primary;
      case MacroType.carbs:
        return LuminaHealthColors.secondary;
      case MacroType.fat:
        return LuminaHealthColors.tertiary;
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
    final scheme = theme.colorScheme;
    
    final hasItems = meal.items.isNotEmpty;
    final firstItemHasImage = hasItems ? (meal.items.first.image?.trim().isNotEmpty ?? false) : false;
    final imageUrl = firstItemHasImage ? meal.items.first.image!.trim() : null;

    final fallbackIcon = Container(
      color: scheme.surfaceContainerHigh,
      child: Center(
        child: Icon(
          hasItems ? meal.items.first.icon ?? Icons.restaurant : Icons.restaurant,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
        ),
      ),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: hasItems ? () => onItemTap(meal.items.first) : null,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                ),
                clipBehavior: Clip.antiAlias,
                child: imageUrl != null 
                    ? Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => fallbackIcon,
                      )
                    : fallbackIcon,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          meal.name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: scheme.onSurface,
                          ),
                        ),
                        Text(
                          '${meal.totalKcal} kcal',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hasItems 
                          ? meal.items.map((e) => e.name).join(', ')
                          : 'No foods logged yet.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(
                Icons.chevron_right,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
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
