import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth_interceptor.dart';
import '../../ui_components/ui_components.dart';
import '../../ui_system/lumina_health_theme.dart';
import '../../ui_system/tokens.dart';
import 'add_food_page.dart';
import 'meal_suggestion.dart';
import 'nutrition_detail_page.dart';
import 'data/api_exceptions.dart';
import 'data/food_local_db.dart';
import 'data/foods_api_service.dart';
import 'data/nutrition_api_service.dart';
import 'data/nutrition_day_cache.dart';
import 'data/off_client.dart';
import 'widgets/meal_detail_sheet.dart';

class NutritionTodayPage extends StatefulWidget {
  const NutritionTodayPage({
    super.key,
    required this.accessToken,
    required this.onLogout,
    this.authInterceptor,
    this.localDb,
    this.foodsApi,
    this.nutritionApi,
    this.dayCache,
    this.offClient,
  });

  final String accessToken;
  final Future<void> Function() onLogout;
  final AuthInterceptor? authInterceptor;
  final FoodLocalDb? localDb;
  final FoodsApiService? foodsApi;
  final NutritionApiService? nutritionApi;
  final NutritionDayCache? dayCache;
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
  late final NutritionDayCache _dayCache;
  late final bool _ownsDayCache;
  late final OffClient _offClient;

  NutritionDayLog? _dayLog;
  // Per-meal windows learned from the user's own history; null until loaded (or
  // if the fetch fails), in which case the smart guess uses population defaults.
  Map<MealType, MealWindow>? _mealWindows;
  Timer? _spinnerTimer;
  bool _showSpinner = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateUtils.dateOnly(DateTime.now());
    _ownsLocalDb = widget.localDb == null;
    _localDb = widget.localDb ?? FoodLocalDb();
    _foodsApi =
        widget.foodsApi ??
        FoodsApiService(
          accessToken: widget.accessToken,
          authInterceptor: widget.authInterceptor,
        );
    _nutritionApi =
        widget.nutritionApi ??
        NutritionApiService(
          accessToken: widget.accessToken,
          authInterceptor: widget.authInterceptor,
        );
    _ownsDayCache = widget.dayCache == null;
    _dayCache = widget.dayCache ?? NutritionDayCache();
    _offClient = widget.offClient ?? OffClient();
    _loadDay();
    _loadMealTimes();
  }

  /// Logs out, first wiping the local day cache so the next user on this device
  /// can't briefly see the previous user's log (the cache isn't per-user).
  Future<void> _handleLogout() async {
    try {
      await _dayCache.clear();
    } catch (_) {
      // Best-effort — never block logout on a cache wipe.
    }
    await widget.onLogout();
  }

  // Best-effort: a failure just leaves the smart meal guess on its defaults.
  Future<void> _loadMealTimes() async {
    try {
      final learned = await _nutritionApi.fetchMealTimes();
      if (!mounted) return;
      setState(() => _mealWindows = buildMealWindows(learned));
    } on ApiException {
      // Ignore — defaults are a fine fallback.
    }
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
    _spinnerTimer?.cancel();
    if (_ownsLocalDb) {
      _localDb.close();
    }
    if (_ownsDayCache) {
      _dayCache.close();
    }
    super.dispose();
  }

  Future<void> _loadDay() async {
    _spinnerTimer?.cancel();
    // Snapshot the date: the cache read and network fetch are async, so the user
    // may switch days before they return. We discard results for a stale date.
    final date = _selectedDate;
    final dateKey = NutritionApiService.formatDate(date);
    setState(() {
      _showSpinner = false;
      _errorMessage = null;
    });

    // 1. Stale: render the cached day instantly so there's no blank screen and
    //    offline opens still show data. Best-effort — a cache miss or failure
    //    just falls through to the spinner + network path below.
    final bool hadCache = await _showCachedDay(dateKey, date);

    // Only show the loading bar if we have nothing on screen yet; with a cache
    // hit the refresh happens silently underneath the already-rendered day.
    if (!hadCache) {
      _spinnerTimer = Timer(const Duration(seconds: 1), () {
        if (!mounted || date != _selectedDate) return;
        setState(() => _showSpinner = true);
      });
    }

    // 2. Revalidate against the server and refresh the cache.
    try {
      final raw = await _nutritionApi.fetchDayRaw(date);
      if (!mounted || date != _selectedDate) {
        return;
      }
      setState(() {
        _dayLog = _nutritionApi.parseDayLog(raw);
        _showSpinner = false;
        _errorMessage = null;
      });
      await _writeCache(dateKey, raw);
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await _handleLogout();
        if (!mounted) return;
        setState(() => _showSpinner = false);
        return;
      }
      if (!mounted || date != _selectedDate) {
        return;
      }
      setState(() {
        _showSpinner = false;
        // Don't bury a usable cached view under an error banner — offline reads
        // should keep working. Only surface the error when there's nothing to
        // show for this day.
        if (!hadCache) {
          _errorMessage = error.message;
        }
      });
    } finally {
      _spinnerTimer?.cancel();
    }
  }

  /// Renders the cached payload for [dateKey] if present and still the selected
  /// day. Returns whether a usable cached day was shown. Best-effort: any cache
  /// or parse failure is swallowed so the network path takes over.
  Future<bool> _showCachedDay(String dateKey, DateTime date) async {
    try {
      final cached = await _dayCache.read(dateKey);
      if (cached == null || !mounted || date != _selectedDate) {
        return false;
      }
      final cachedLog = _nutritionApi.parseDayLog(cached);
      setState(() {
        _dayLog = cachedLog;
        _errorMessage = null;
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeCache(String dateKey, Map<String, dynamic> raw) async {
    try {
      await _dayCache.write(dateKey, raw);
    } catch (_) {
      // Best-effort cache; failing to persist never breaks the view.
    }
  }

  void _changeDate(int deltaDays) {
    final next = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day + deltaDays,
    );
    final today = DateUtils.dateOnly(DateTime.now());
    if (next.isAfter(today)) {
      return;
    }
    setState(() {
      _selectedDate = next;
    });
    _loadDay();
  }

  Future<void> _pickDate(BuildContext context) async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picker = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: today,
    );
    if (picker == null) return;
    if (picker == _selectedDate) return;
    setState(() {
      _selectedDate = picker;
    });
    await _loadDay();
  }

  void _setTodayDate() {
    _selectedDate = DateUtils.dateOnly(DateTime.now());
    _loadDay();
  }

  String _dateLabel() {
    final today = DateUtils.dateOnly(DateTime.now());
    final diff = today.difference(_selectedDate).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[_selectedDate.month - 1]} ${_selectedDate.day}';
  }

  Future<void> _openAddFoodSheet(
    BuildContext context, {
    MealType? initialMeal,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    // When opened from the generic "+" (no explicit meal), guess the meal from
    // the time of day and what's already been logged today.
    final meal =
        initialMeal ??
        suggestMealType(
          now: DateTime.now(),
          mealsLogged: _dayLog?.meals ?? const {},
          windows: _mealWindows,
        );
    final didAdd = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddFoodPage(
          localDb: _localDb,
          foodsApi: _foodsApi,
          nutritionApi: _nutritionApi,
          offClient: _offClient,
          onLogout: _handleLogout,
          selectedDate: _selectedDate,
          initialMeal: meal,
        ),
      ),
    );
    if (!mounted || didAdd != true) {
      return;
    }
    await _loadDay();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Meal logged'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _openMealDetails(BuildContext context, _MealSummary meal) async {
    if (meal.entries.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MealDetailSheet(
        mealLabel: meal.name,
        mealIcon: meal.icon,
        entries: meal.entries,
        onUpdateQuantity: (entry, grams) => _updateEntryQuantity(entry, grams),
        onDeleteEntry: (entry) => _deleteEntry(entry),
        onAddMore: () {
          Navigator.of(context).pop();
          _openAddFoodSheet(context, initialMeal: meal.mealType);
        },
      ),
    );
    // Reload after the sheet closes so the calorie ring and macro bars reflect
    // any edits or deletes made inside it. A no-op refetch when nothing changed.
    if (!mounted) return;
    await _loadDay();
  }

  void _openNutrientDetail(BuildContext context) {
    final entries =
        _dayLog?.meals.values.expand((list) => list).toList() ??
        const <NutritionEntry>[];
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NutritionDetailPage(
          dateLabel: _dateLabel(),
          eatenKcal: _dayLog?.totals.kcal.round() ?? 0,
          entries: entries,
        ),
      ),
    );
  }

  Future<NutritionEntry?> _updateEntryQuantity(
    NutritionEntry entry,
    double grams,
  ) async {
    try {
      return await _nutritionApi.updateEntry(
        entryId: entry.id,
        quantityG: grams,
      );
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await _handleLogout();
        return null;
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
      return null;
    }
  }

  Future<bool> _deleteEntry(NutritionEntry entry) async {
    try {
      await _nutritionApi.deleteEntry(entry.id);
      return true;
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await _handleLogout();
        return false;
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
      return false;
    }
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

  List<_MealSummary> _buildMealSummaries() {
    final Map<String, List<NutritionEntry>> meals = _dayLog?.meals ?? {};
    final order = <String, ({MealType type, IconData icon, String label})>{
      'breakfast': (
        type: MealType.breakfast,
        icon: Icons.breakfast_dining,
        label: 'Breakfast',
      ),
      'lunch': (type: MealType.lunch, icon: Icons.lunch_dining, label: 'Lunch'),
      'dinner': (
        type: MealType.dinner,
        icon: Icons.dinner_dining,
        label: 'Dinner',
      ),
      'snacks': (
        type: MealType.snacks,
        icon: Icons.emoji_food_beverage,
        label: 'Snacks',
      ),
    };

    final summaries = <_MealSummary>[];
    for (final entry in order.entries) {
      final meta = entry.value;
      summaries.add(
        _MealSummary(
          name: meta.label,
          mealType: meta.type,
          icon: meta.icon,
          entries: meals[entry.key] ?? const [],
        ),
      );
    }
    return summaries;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final totals = _dayLog?.totals;
    final eatenKcal = totals?.kcal.round() ?? 0;
    final burnedKcal = _burnedKcal;
    // Exercise adds to the day's budget; "remaining" can now go negative, which
    // we surface as an over-budget amount rather than clamping to zero.
    final int kcalBudget = _dailyGoalKcal + burnedKcal;
    final int kcalRemaining = kcalBudget - eatenKcal;
    final bool kcalOver = kcalRemaining < 0;
    final int kcalCenterValue = kcalRemaining.abs();
    final double ringProgress = kcalBudget > 0
        ? (eatenKcal / kcalBudget).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final Color ringColor = kcalOver
        ? LuminaHealthColors.warning
        : scheme.primary;
    final macroSummaries = _buildMacroSummaries(totals);
    final mealSummaries = _buildMealSummaries();
    final isToday = DateUtils.isSameDay(_selectedDate, DateTime.now());

    // Calculate total entries
    final totalEntries =
        _dayLog?.meals.values.fold<int>(0, (sum, list) => sum + list.length) ??
        0;

    return AppScaffold(
      safeArea: false,
      padding: EdgeInsets.zero,
      appBar: AppBar(
        actions: [
          IconButton(
            onPressed: () => _handleLogout(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(color: scheme.surface),
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
                  if (_showSpinner)
                    SliverToBoxAdapter(
                      key: const Key("nutritionLoadingSpinner"),
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
                        horizontal: AppSpacing.lg,
                        vertical: AppSpacing.sm,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.chevron_left),
                            color: LuminaHealthColors.primary,
                            onPressed: () => _changeDate(-1),
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'SYMBIO',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: LuminaHealthColors.primary.withValues(
                                    alpha: 0.6,
                                  ),
                                  letterSpacing: 2.0,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 10,
                                ),
                              ),
                              InkWell(
                                onTap: () => _pickDate(context),
                                onDoubleTap: () => _setTodayDate(),
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.sm,
                                    vertical: AppSpacing.xs,
                                  ),
                                  child: Text(
                                    _dateLabel(),
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      color: LuminaHealthColors.primary,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.chevron_right),
                            color: isToday ? null : LuminaHealthColors.primary,
                            onPressed: isToday ? null : () => _changeDate(1),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Hero Biometric Section
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                        vertical: AppSpacing.md,
                      ),
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
                                  progressColor: ringColor,
                                  glowColor: ringColor,
                                  glowLevel: PulseGlowLevel.high,
                                ),
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      kcalOver
                                          ? '+$kcalCenterValue'
                                          : '$kcalCenterValue',
                                      style: theme.textTheme.displayLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w800,
                                            height: 1,
                                            color: kcalOver
                                                ? LuminaHealthColors.warning
                                                : null,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      kcalOver ? 'OVER' : 'LEFT',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 2.0,
                                            color: kcalOver
                                                ? LuminaHealthColors.warning
                                                : scheme.onSurfaceVariant,
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
                                          color: scheme.primary.withValues(
                                            alpha: 0.2,
                                          ),
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
                                                color:
                                                    LuminaHealthColors.tertiary,
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
                        horizontal: AppSpacing.lg,
                        vertical: AppSpacing.md,
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow.withValues(
                            alpha: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.05),
                          ),
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
                            final accent = _macroAccent(macro.type);
                            final over = macro.current - macro.goal;
                            final isOver = over > 0;
                            final progress = macro.goal > 0
                                ? (macro.current / macro.goal).clamp(0.0, 1.0)
                                : 0.0;
                            final treatment = isOver
                                ? _macroOverTreatment(macro.type)
                                : null;
                            final barColor = treatment?.barColor ?? accent;
                            final valueColor = treatment?.textColor ?? accent;
                            final statusText = isOver
                                ? '+${over}g ${treatment!.suffix}'
                                : '${macro.goal - macro.current}g left';
                            final statusColor =
                                treatment?.textColor ??
                                scheme.onSurface.withValues(alpha: 0.6);
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
                                                color: valueColor,
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
                                      color: barColor,
                                      minHeight: 6,
                                      borderRadius: BorderRadius.circular(9999),
                                    ),
                                    const SizedBox(height: AppSpacing.xs),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: Text(
                                        statusText,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: statusColor,
                                              fontSize: 10,
                                              fontWeight: isOver
                                                  ? FontWeight.bold
                                                  : null,
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
                  // Full nutrient breakdown entry point
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => _openNutrientDetail(context),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm,
                              vertical: AppSpacing.md,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.insights,
                                  size: 18,
                                  color: scheme.primary,
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  child: Text(
                                    'View full nutrients',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: scheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right,
                                  color: scheme.primary,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Daily Logs Header
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.sm,
                      ),
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
                    delegate: SliverChildBuilderDelegate((context, index) {
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
                          onTap: () => _openMealDetails(context, meal),
                        ),
                      );
                    }, childCount: mealSummaries.length),
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

  // How each macro reads once its goal is exceeded. The semantics differ per
  // nutrient: hitting protein is a goal to celebrate, going over fat is a
  // cautionary warning, and exceeding carbs is neutral information.
  ({Color textColor, Color barColor, String suffix}) _macroOverTreatment(
    MacroType type,
  ) {
    switch (type) {
      case MacroType.protein:
        return (
          textColor: LuminaHealthColors.primary,
          barColor: LuminaHealthColors.primary,
          suffix: '✓',
        );
      case MacroType.fat:
        return (
          textColor: LuminaHealthColors.warning,
          barColor: LuminaHealthColors.warning,
          suffix: 'over',
        );
      case MacroType.carbs:
        return (
          textColor: LuminaHealthColors.onSurfaceVariant,
          barColor: LuminaHealthColors.secondary,
          suffix: 'over',
        );
    }
  }
}

class _MealCard extends StatelessWidget {
  const _MealCard({required this.meal, required this.onTap});

  final _MealSummary meal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final hasItems = meal.entries.isNotEmpty;
    final firstImage = hasItems
        ? meal.entries.first.foodItem.imageUrl?.trim()
        : null;
    final imageUrl = (firstImage != null && firstImage.isNotEmpty)
        ? firstImage
        : null;

    final fallbackIcon = Container(
      color: scheme.surfaceContainerHigh,
      child: Center(
        child: Icon(
          meal.icon,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
        ),
      ),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: hasItems ? onTap : null,
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
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: imageUrl != null
                    ? Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            fallbackIcon,
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
                          ? meal.entries.map((e) => e.foodItem.name).join(', ')
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
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
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

class _MealSummary {
  const _MealSummary({
    required this.name,
    required this.mealType,
    required this.icon,
    required this.entries,
  });

  final String name;
  final MealType mealType;
  final IconData icon;
  final List<NutritionEntry> entries;

  int get totalKcal =>
      entries.fold<int>(0, (total, entry) => total + entry.kcal.round());
}
