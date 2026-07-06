import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth_interceptor.dart';
import '../../ui_components/ui_components.dart';
import '../../ui_system/lumina_health_theme.dart';
import '../../ui_system/tokens.dart';
import 'add_food_page.dart';
import 'food_detail_page.dart';
import 'meal_suggestion.dart';
import 'nutrition_detail_page.dart';
import 'data/api_exceptions.dart';
import 'data/food_local_db.dart';
import 'data/food_models.dart';
import 'data/foods_api_service.dart';
import 'data/nutrient_catalog.dart';
import 'data/nutrition_api_service.dart';
import 'data/nutrition_local_store.dart';
import 'data/nutrition_repository.dart';
import 'data/off_client.dart';
import 'data/user_preferences.dart';
import 'widgets/meal_detail_sheet.dart';
import 'widgets/nutrient_breakdown_view.dart' show formatNutrientValue;

class NutritionTodayPage extends StatefulWidget {
  const NutritionTodayPage({
    super.key,
    required this.accessToken,
    required this.onLogout,
    this.authInterceptor,
    this.localDb,
    this.foodsApi,
    this.nutritionApi,
    this.localStore,
    this.offClient,
    this.preferences,
  });

  final String accessToken;
  final Future<void> Function() onLogout;
  final AuthInterceptor? authInterceptor;
  final FoodLocalDb? localDb;
  final FoodsApiService? foodsApi;
  final NutritionApiService? nutritionApi;
  final NutritionLocalStore? localStore;
  final OffClient? offClient;

  /// The user's saved goals/units, owned by the shell and passed down so the
  /// day's macros/calories reflect edits made on the account tab. Null while
  /// still loading (or when shown standalone) → macros/calories fall back to the
  /// catalog defaults.
  final UserPreferences? preferences;

  @override
  State<NutritionTodayPage> createState() => _NutritionTodayPageState();
}

class _NutritionTodayPageState extends State<NutritionTodayPage> {
  late DateTime _selectedDate;
  late final FoodLocalDb _localDb;
  late final bool _ownsLocalDb;
  late final FoodsApiService _foodsApi;
  late final NutritionApiService _nutritionApi;
  late final NutritionLocalStore _localStore;
  late final bool _ownsLocalStore;
  late final NutritionRepository _repository;
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
    _ownsLocalStore = widget.localStore == null;
    _localStore = widget.localStore ?? NutritionLocalStore();
    _repository = NutritionRepository(api: _nutritionApi, store: _localStore);
    _offClient = widget.offClient ?? OffClient();
    _loadDay();
    _loadMealTimes();
  }

  /// The catalog with the user's saved goals layered on. The single source of
  /// truth for every nutrient target the today and detail pages show.
  List<NutrientSpec> get _catalog =>
      resolveCatalog(widget.preferences?.nutrientGoals);

  int get _calorieGoal =>
      widget.preferences?.calorieGoal ?? kDefaultCalorieGoal;

  /// The user's focus nutrients resolved against the goal-adjusted catalog, so
  /// each tile's target already reflects any personalized goal.
  List<NutrientSpec> get _focusSpecs =>
      resolveFocusSpecs(widget.preferences?.focusNutrients, base: _catalog);

  /// Logs out, first wiping the local nutrition store so the next user on this
  /// device can't see the previous user's log and no leftover offline outbox
  /// can replay into another account (the store isn't per-user).
  Future<void> _handleLogout() async {
    try {
      await _repository.clear();
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
    if (_ownsLocalStore) {
      _localStore.close();
    }
    super.dispose();
  }

  Future<void> _loadDay() async {
    _spinnerTimer?.cancel();
    // Snapshot the date: the local read and network sync are async, so the user
    // may switch days before they return. We discard results for a stale date.
    final date = _selectedDate;
    setState(() {
      _showSpinner = false;
      _errorMessage = null;
    });

    // 1. Stale: render the locally known day instantly so there's no blank
    //    screen; offline opens (and offline-logged meals) show right away.
    //    Best-effort — a store miss or failure just falls through to the
    //    spinner + network path below.
    final bool hadLocal = await _showLocalDay(date);

    // Only show the loading bar if we have nothing on screen yet; with a local
    // hit the sync happens silently underneath the already-rendered day.
    if (!hadLocal) {
      _spinnerTimer = Timer(const Duration(seconds: 1), () {
        if (!mounted || date != _selectedDate) return;
        setState(() => _showSpinner = true);
      });
    }

    // 2. Converge with the server: replay any queued offline writes, pull
    //    deltas (or the day's first full fetch) and re-render.
    try {
      final fresh = await _repository.refreshDay(date);
      if (!mounted || date != _selectedDate) {
        return;
      }
      setState(() {
        _dayLog = fresh;
        _showSpinner = false;
        _errorMessage = null;
      });
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
        // Don't bury a usable local view under an error banner — offline reads
        // should keep working. Only surface the error when there's nothing to
        // show for this day.
        if (!hadLocal) {
          _errorMessage = error.message;
        }
      });
    } finally {
      _spinnerTimer?.cancel();
    }
  }

  /// Renders the locally known state for [date] if any and still the selected
  /// day. Returns whether a usable local day was shown. Best-effort: any store
  /// or parse failure is swallowed so the network path takes over.
  Future<bool> _showLocalDay(DateTime date) async {
    try {
      final local = await _repository.readCachedDay(date);
      if (local == null || !mounted || date != _selectedDate) {
        return false;
      }
      setState(() {
        _dayLog = local;
        _errorMessage = null;
      });
      return true;
    } catch (_) {
      return false;
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
    setState(() {
      _selectedDate = DateUtils.dateOnly(DateTime.now());
    });
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
          repository: _repository,
          offClient: _offClient,
          onLogout: _handleLogout,
          selectedDate: _selectedDate,
          initialMeal: meal,
          focusSpecs: _focusSpecs,
          catalog: _catalog,
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
        mealTypeName: meal.mealType.name,
        mealIcon: meal.icon,
        entries: meal.entries,
        focusSpecs: _focusSpecs,
        onUpdateEntry: (entry, {quantityG, mealType}) =>
            _updateEntry(entry, quantityG: quantityG, mealType: mealType),
        onDeleteEntry: (entry) => _deleteEntry(entry),
        onViewFoodDetails: _openFoodDetail,
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

  /// Pushes the read-first food page (KAN-33) for a logged food. Resolves
  /// with the item as edited there (null = unchanged); the day itself is
  /// refreshed by the meal sheet's dismissal reload.
  Future<FoodItem?> _openFoodDetail(FoodItem item) async {
    FoodItem? updated;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FoodDetailPage(
          item: item,
          foodsApi: _foodsApi,
          localDb: _localDb,
          onLogout: _handleLogout,
          catalog: _catalog,
          onItemChanged: (next) => updated = next,
        ),
      ),
    );
    return updated;
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
          serverNutrients: _dayLog?.nutrients,
          nutrientGoals: widget.preferences?.nutrientGoals,
        ),
      ),
    );
  }

  Future<NutritionEntry?> _updateEntry(
    NutritionEntry entry, {
    double? quantityG,
    String? mealType,
  }) async {
    try {
      // Applies locally right away and queues the server write when offline
      // (KAN-28) — so the edit sticks even with no connectivity.
      return await _repository.updateEntry(
        entry,
        quantityG: quantityG,
        mealType: mealType,
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
      return await _repository.deleteEntry(entry);
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

  /// One summary per focus nutrient, in the user's chosen order. Amounts come
  /// from the server's per-day nutrients map; the classic macros fall back to
  /// the totals block (older cached payloads lack the map), and anything else
  /// falls back to a client-side aggregate over the day's entries. A null
  /// amount means foods were logged but none reported the nutrient ("no data");
  /// an empty day reads as a plain 0 so a fresh morning isn't full of dashes.
  List<_FocusSummary> _buildFocusSummaries(NutritionTotals? totals) {
    final specs = _focusSpecs;
    final entries =
        _dayLog?.meals.values.expand((list) => list).toList() ??
        const <NutritionEntry>[];

    Map<String, NutrientTotal>? aggregated;
    if (_dayLog?.nutrients == null && entries.isNotEmpty) {
      aggregated = {
        for (final total in aggregateNutrients(entries, catalog: specs))
          total.spec.key: total,
      };
    }

    return [
      for (final spec in specs)
        () {
          double? amount = _serverAmount(spec.key);
          amount ??= switch (spec.key) {
            'protein' => totals?.proteinG,
            'carbs' => totals?.carbsG,
            'fat' => totals?.fatG,
            _ => aggregated?[spec.key]?.amount,
          };
          if (amount == null && entries.isEmpty) amount = 0;
          final incomplete =
              _nutrientIncomplete(spec.key) ||
              (aggregated?[spec.key]?.isIncomplete ?? false);
          return _FocusSummary(
            spec: spec,
            amount: amount,
            incomplete: incomplete,
          );
        }(),
    ];
  }

  /// The day amount for [key] from the server's per-day nutrients map, or null
  /// when the map is absent or carries no data for it.
  double? _serverAmount(String key) {
    final raw = _dayLog?.nutrients?[key];
    if (raw is! Map) return null;
    return (raw['amount'] as num?)?.toDouble();
  }

  /// Whether a nutrient's day total is a floor: some — but not all — of the
  /// day's foods reported it, so the total silently omits the rest. Read from
  /// the server's per-nutrient reported/total counts; false when unavailable.
  bool _nutrientIncomplete(String key) {
    final raw = _dayLog?.nutrients?[key];
    if (raw is! Map) return false;
    final total = (raw['total'] as num?)?.toInt();
    final reported = (raw['reported'] as num?)?.toInt();
    if (total == null || reported == null) return false;
    return reported > 0 && reported < total;
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
    final int kcalBudget = _calorieGoal + burnedKcal;
    final int kcalRemaining = kcalBudget - eatenKcal;
    final bool kcalOver = kcalRemaining < 0;
    final int kcalCenterValue = kcalRemaining.abs();
    final double ringProgress = kcalBudget > 0
        ? (eatenKcal / kcalBudget).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final Color ringColor = kcalOver
        ? LuminaHealthColors.warning
        : scheme.primary;
    final focusSummaries = _buildFocusSummaries(totals);
    final mealSummaries = _buildMealSummaries();
    final isToday = DateUtils.isSameDay(_selectedDate, DateTime.now());

    // Calculate total entries
    final totalEntries =
        _dayLog?.meals.values.fold<int>(0, (sum, list) => sum + list.length) ??
        0;

    return AppScaffold(
      safeArea: false,
      padding: EdgeInsets.zero,
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
                  // Wordmark scrolls away with the content; only the compact
                  // date bar below stays pinned (KAN-34).
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Center(
                        child: Text(
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
                      ),
                    ),
                  ),
                  // Pinned compact date bar so the viewed day is visible at
                  // any scroll position. Transparent at rest (the hero
                  // gradient shows through); opaque once meal cards scroll
                  // under it so they don't visually collide.
                  SliverAppBar(
                    pinned: true,
                    primary: false,
                    automaticallyImplyLeading: false,
                    toolbarHeight: 52,
                    titleSpacing: AppSpacing.sm,
                    backgroundColor: WidgetStateColor.resolveWith(
                      (states) => states.contains(WidgetState.scrolledUnder)
                          ? scheme.surface
                          : Colors.transparent,
                    ),
                    title: Row(
                      children: [
                        IconButton(
                          tooltip: 'Previous day',
                          icon: const Icon(Icons.chevron_left),
                          color: LuminaHealthColors.primary,
                          onPressed: () => _changeDate(-1),
                        ),
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Flexible(
                                child: InkWell(
                                  onTap: () => _pickDate(context),
                                  // Kept as a shortcut; the Today chip is the
                                  // discoverable affordance.
                                  onDoubleTap: () => _setTodayDate(),
                                  borderRadius: BorderRadius.circular(8),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: AppSpacing.sm,
                                      vertical: AppSpacing.xs,
                                    ),
                                    child: Text(
                                      _dateLabel(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleLarge
                                          ?.copyWith(
                                            color: LuminaHealthColors.primary,
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                              if (!isToday)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: AppSpacing.sm,
                                  ),
                                  child: ActionChip(
                                    key: const Key('todayChip'),
                                    tooltip: 'Back to today',
                                    onPressed: _setTodayDate,
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: scheme.primary.withValues(
                                      alpha: 0.1,
                                    ),
                                    side: BorderSide(
                                      color: scheme.primary.withValues(
                                        alpha: 0.3,
                                      ),
                                    ),
                                    label: Text(
                                      'Today',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: scheme.primary,
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Next day',
                          icon: const Icon(Icons.chevron_right),
                          color: isToday ? null : LuminaHealthColors.primary,
                          onPressed: isToday ? null : () => _changeDate(1),
                        ),
                      ],
                    ),
                    // Always-reserved slot for the loading bar so its
                    // appearance doesn't shift content (KAN-25).
                    bottom: PreferredSize(
                      preferredSize: const Size.fromHeight(2),
                      child: SizedBox(
                        height: 2,
                        child: _showSpinner
                            ? Padding(
                                key: const Key("nutritionLoadingSpinner"),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.lg,
                                ),
                                child: LinearProgressIndicator(
                                  minHeight: 2,
                                  color: scheme.primary,
                                  backgroundColor: scheme.surfaceContainer,
                                ),
                              )
                            : null,
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
                        child: _buildFocusLayout(context, focusSummaries),
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

  /// The focus tiles laid out for the card: a single row for up to three, a
  /// 2×2 grid for four (four labels + values in one row would be cramped).
  /// Slot accents come from [LuminaHealthColors.focusAccents] so the card
  /// matches the amount-sheet pills and add-meal summary.
  Widget _buildFocusLayout(
    BuildContext context,
    List<_FocusSummary> summaries,
  ) {
    final tiles = [
      for (var i = 0; i < summaries.length; i++)
        Expanded(
          child: _buildFocusTile(
            context,
            summaries[i],
            LuminaHealthColors.focusAccents[i %
                LuminaHealthColors.focusAccents.length],
          ),
        ),
    ];
    const gap = SizedBox(width: AppSpacing.md);
    if (tiles.length <= 3) {
      return Row(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[if (i > 0) gap, tiles[i]],
        ],
      );
    }
    return Column(
      children: [
        Row(children: [tiles[0], gap, tiles[1]]),
        const SizedBox(height: AppSpacing.md),
        Row(children: [tiles[2], gap, tiles[3]]),
      ],
    );
  }

  // How a nutrient reads once its goal is exceeded. Cautionary nutrients
  // (sugars, sodium, ... and fat, historically) warn; carbs over is neutral
  // information; everything else — protein, fiber, vitamins, minerals — hit
  // their target, which is the goal, so they celebrate.
  ({Color textColor, Color barColor, String suffix}) _overTreatment(
    NutrientSpec spec,
    Color accent,
  ) {
    if (spec.overIsBad || spec.key == 'fat') {
      return (
        textColor: LuminaHealthColors.warning,
        barColor: LuminaHealthColors.warning,
        suffix: 'over',
      );
    }
    if (spec.key == 'carbs') {
      return (
        textColor: LuminaHealthColors.onSurfaceVariant,
        barColor: accent,
        suffix: 'over',
      );
    }
    return (textColor: accent, barColor: accent, suffix: '✓');
  }

  Widget _buildFocusTile(
    BuildContext context,
    _FocusSummary summary,
    Color accent,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final spec = summary.spec;
    // Grams read as "150g"; other units keep a thin space ("320 mg").
    final unit = spec.unit == 'g' ? 'g' : ' ${spec.unit}';

    final amount = summary.amount;
    final noData = amount == null;
    final goal = spec.dailyTarget;
    final over = noData ? 0.0 : amount - goal;
    // A floor total's over/left is unreliable, so the incomplete hint takes
    // precedence over over-limit.
    final incomplete = !noData && summary.incomplete;
    final isOver = !noData && !incomplete && over > 0;
    final progress = noData || goal <= 0
        ? 0.0
        : (amount / goal).clamp(0.0, 1.0).toDouble();
    final treatment = isOver ? _overTreatment(spec, accent) : null;
    final barColor = incomplete
        ? accent.withValues(alpha: 0.35)
        : treatment?.barColor ?? accent;
    final valueColor = noData || incomplete
        ? scheme.onSurfaceVariant
        : treatment?.textColor ?? accent;
    final valueText = noData
        ? '—'
        : '${incomplete ? '~' : ''}${formatNutrientValue(amount)}$unit';
    final statusText = noData
        ? 'no data'
        : incomplete
        ? 'incomplete'
        : isOver
        ? '+${formatNutrientValue(over)}$unit ${treatment!.suffix}'
        : '${formatNutrientValue(goal - amount)}$unit left';
    final statusColor = noData || incomplete
        ? scheme.onSurfaceVariant
        : treatment?.textColor ?? scheme.onSurface.withValues(alpha: 0.6);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                spec.label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurfaceVariant,
                  letterSpacing: -0.5,
                  fontSize: 10,
                ),
              ),
            ),
            Text(
              valueText,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: valueColor,
                fontSize: 10,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        LinearProgressIndicator(
          value: progress,
          backgroundColor: scheme.surfaceContainerHighest,
          color: barColor,
          minHeight: 6,
          borderRadius: BorderRadius.circular(9999),
        ),
        const SizedBox(height: AppSpacing.xs),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            statusText,
            style: theme.textTheme.labelSmall?.copyWith(
              color: statusColor,
              fontSize: 10,
              fontWeight: isOver ? FontWeight.bold : null,
              fontStyle: incomplete || noData ? FontStyle.italic : null,
            ),
          ),
        ),
      ],
    );
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

const int _burnedKcal = 0;

/// One focus nutrient's day state. [amount] is in the spec's canonical unit;
/// null means foods were logged but none reported this nutrient.
class _FocusSummary {
  const _FocusSummary({
    required this.spec,
    required this.amount,
    this.incomplete = false,
  });

  final NutrientSpec spec;
  final double? amount;

  /// The total is a floor — some of the day's foods didn't report it.
  final bool incomplete;
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
