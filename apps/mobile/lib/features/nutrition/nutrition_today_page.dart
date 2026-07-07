import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth_interceptor.dart';
import '../../ui_components/ui_components.dart';
import '../../ui_system/lumina_health_theme.dart';
import '../../ui_system/tokens.dart';
import 'add_food_page.dart';
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
import 'food_detail_page.dart';
import 'meal_suggestion.dart';
import 'nutrition_detail_page.dart';
import 'widgets/amount_sheet.dart' show mealTypeIcon;
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

  // Entries with offline writes still queued in the outbox (KAN-56). Non-zero
  // shows the "waiting to sync" chip; refreshed after every load and write
  // since those are the only moments the outbox changes shape.
  int _pendingSyncCount = 0;

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

  /// The nutrients the user opted into over-goal warnings for (KAN-38). Empty
  /// by default — only the calorie ring warns until the user picks more.
  Set<String> get _warnNutrients => {
    ...widget.preferences?.warnNutrients ?? const <String>[],
  };

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
      await _refreshPendingSync();
    }
  }

  /// Re-reads the outbox-pending count and updates the chip. Best-effort:
  /// a store failure just leaves the last known value.
  Future<void> _refreshPendingSync() async {
    try {
      final count = await _repository.pendingSyncCount();
      if (!mounted || count == _pendingSyncCount) return;
      setState(() => _pendingSyncCount = count);
    } catch (_) {
      // Non-critical indicator — never let it break the page.
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
          warnNutrients: _warnNutrients,
        ),
      ),
    );
    // Reload even when the page reports no clean submit: a partially failed
    // submit (KAN-53) has already logged some items, and backing out must not
    // leave them off the day view. A no-op refetch when nothing changed.
    if (!mounted) return;
    await _loadDay();
    if (!mounted || didAdd != true) return;
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
        warnNutrients: _warnNutrients,
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
  Future<FoodItem?> _openFoodDetail(FoodItem item) {
    return pushFoodDetailPage(
      context,
      item: item,
      foodsApi: _foodsApi,
      localDb: _localDb,
      onLogout: _handleLogout,
      catalog: _catalog,
    );
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
          warnNutrients: _warnNutrients,
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
      final updated = await _repository.updateEntry(
        entry,
        quantityG: quantityG,
        mealType: mealType,
      );
      unawaited(_refreshPendingSync());
      return updated;
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
      final deleted = await _repository.deleteEntry(entry);
      unawaited(_refreshPendingSync());
      return deleted;
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
    return [
      for (final meal in MealType.values)
        _MealSummary(
          name: meal.label,
          mealType: meal,
          icon: mealTypeIcon(meal),
          entries: meals[meal.wireName] ?? const [],
        ),
    ];
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
                  _DateBar(
                    dateLabel: _dateLabel(),
                    isToday: isToday,
                    showSpinner: _showSpinner,
                    onPreviousDay: () => _changeDate(-1),
                    onNextDay: () => _changeDate(1),
                    onPickDate: () => _pickDate(context),
                    onSetToday: _setTodayDate,
                  ),
                  if (_pendingSyncCount > 0)
                    SliverToBoxAdapter(
                      child: _PendingSyncChip(count: _pendingSyncCount),
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
                      child: _HeroSection(
                        ringProgress: ringProgress,
                        ringColor: ringColor,
                        kcalOver: kcalOver,
                        kcalCenterValue: kcalCenterValue,
                        eatenKcal: eatenKcal,
                        burnedKcal: burnedKcal,
                        onAddFood: () => _openAddFoodSheet(context),
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
                      child: _FocusCard(
                        summaries: focusSummaries,
                        warnNutrients: _warnNutrients,
                      ),
                    ),
                  ),
                  // Full nutrient breakdown entry point
                  SliverToBoxAdapter(
                    child: _ViewFullNutrientsLink(
                      onTap: () => _openNutrientDetail(context),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _DailyLogsHeader(totalEntries: totalEntries),
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
}

/// Pinned compact date bar so the viewed day is visible at any scroll
/// position. Transparent at rest (the hero gradient shows through); opaque
/// once meal cards scroll under it so they don't visually collide. Reserves
/// a fixed slot for the loading bar so its appearance doesn't shift content
/// (KAN-25).
class _DateBar extends StatelessWidget {
  const _DateBar({
    required this.dateLabel,
    required this.isToday,
    required this.showSpinner,
    required this.onPreviousDay,
    required this.onNextDay,
    required this.onPickDate,
    required this.onSetToday,
  });

  final String dateLabel;
  final bool isToday;
  final bool showSpinner;
  final VoidCallback onPreviousDay;
  final VoidCallback onNextDay;
  final VoidCallback onPickDate;
  final VoidCallback onSetToday;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SliverAppBar(
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
            onPressed: onPreviousDay,
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: InkWell(
                    // No onDoubleTap here: a second recognizer forces every
                    // tap to wait out the ~300ms disambiguation window
                    // (KAN-57). The Today chip covers the jump-to-today case.
                    onTap: onPickDate,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xs,
                      ),
                      child: Text(
                        dateLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: LuminaHealthColors.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                if (!isToday)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.sm),
                    child: ActionChip(
                      key: const Key('todayChip'),
                      tooltip: 'Back to today',
                      onPressed: onSetToday,
                      visualDensity: VisualDensity.compact,
                      backgroundColor: scheme.primary.withValues(alpha: 0.1),
                      side: BorderSide(
                        color: scheme.primary.withValues(alpha: 0.3),
                      ),
                      label: Text(
                        'Today',
                        style: theme.textTheme.labelSmall?.copyWith(
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
            onPressed: isToday ? null : onNextDay,
          ),
        ],
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(2),
        child: SizedBox(
          height: 2,
          child: showSpinner
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
    );
  }
}

/// Subtle "waiting to sync" indicator under the date bar (KAN-56): offline
/// writes land in the outbox and the day still says "Meal logged", so this is
/// the only signal that other devices won't see the change until this one
/// reconnects. Disappears once the outbox drains.
class _PendingSyncChip extends StatelessWidget {
  const _PendingSyncChip({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = count == 1
        ? '1 change waiting to sync'
        : '$count changes waiting to sync';
    return Center(
      child: Container(
        key: const Key('pendingSyncChip'),
        margin: const EdgeInsets.only(top: AppSpacing.xs),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: LuminaHealthColors.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_upload_outlined,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The hero biometric block: calorie ring (remaining/over + add button) over
/// the eaten/burned stats row.
class _HeroSection extends StatelessWidget {
  const _HeroSection({
    required this.ringProgress,
    required this.ringColor,
    required this.kcalOver,
    required this.kcalCenterValue,
    required this.eatenKcal,
    required this.burnedKcal,
    required this.onAddFood,
  });

  final double ringProgress;
  final Color ringColor;
  final bool kcalOver;
  final int kcalCenterValue;
  final int eatenKcal;
  final int burnedKcal;
  final VoidCallback onAddFood;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      children: [
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
                trackColor: scheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                progressColor: ringColor,
                glowColor: ringColor,
                glowLevel: PulseGlowLevel.high,
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    kcalOver ? '+$kcalCenterValue' : '$kcalCenterValue',
                    style: theme.textTheme.displayLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1,
                      color: kcalOver ? LuminaHealthColors.warning : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    kcalOver ? 'OVER' : 'LEFT',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.0,
                      color: kcalOver
                          ? LuminaHealthColors.warning
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  IconButton(
                    onPressed: onAddFood,
                    icon: const Icon(Icons.add),
                    style: IconButton.styleFrom(
                      backgroundColor: scheme.primary.withValues(alpha: 0.1),
                      foregroundColor: scheme.primary,
                      side: BorderSide(
                        color: scheme.primary.withValues(alpha: 0.2),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Row(
          children: [
            Expanded(
              child: _KcalStat(
                label: 'EATEN',
                kcal: eatenKcal,
                color: scheme.primary,
                alignEnd: false,
              ),
            ),
            Expanded(
              child: _KcalStat(
                label: 'BURNED',
                kcal: burnedKcal,
                color: LuminaHealthColors.tertiary,
                alignEnd: true,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// One labelled kcal figure of the eaten/burned pair under the ring.
class _KcalStat extends StatelessWidget {
  const _KcalStat({
    required this.label,
    required this.kcal,
    required this.color,
    required this.alignEnd,
  });

  final String label;
  final int kcal;
  final Color color;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
            letterSpacing: 2.0,
            color: scheme.onSurfaceVariant,
            fontSize: 10,
          ),
        ),
        Row(
          mainAxisAlignment: alignEnd
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$kcal',
              style: theme.textTheme.headlineLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
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
    );
  }
}

/// The bordered focus-nutrients card: a single row of tiles for up to three,
/// a 2×2 grid for four (four labels + values in one row would be cramped).
/// Slot accents come from [LuminaHealthColors.focusAccents] so the card
/// matches the amount-sheet pills and add-meal summary.
class _FocusCard extends StatelessWidget {
  const _FocusCard({required this.summaries, required this.warnNutrients});

  final List<_FocusSummary> summaries;
  final Set<String> warnNutrients;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tiles = [
      for (var i = 0; i < summaries.length; i++)
        Expanded(
          child: _FocusTile(
            summary: summaries[i],
            accent: LuminaHealthColors
                .focusAccents[i % LuminaHealthColors.focusAccents.length],
            warnNutrients: warnNutrients,
          ),
        ),
    ];
    const gap = SizedBox(width: AppSpacing.md);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: LuminaHealthColors.hairline),
        boxShadow: [
          BoxShadow(
            color: LuminaHealthColors.hairline,
            offset: const Offset(0, 2),
            blurRadius: 4,
            spreadRadius: 0,
            blurStyle: BlurStyle.inner,
          ),
        ],
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: tiles.length <= 3
          ? Row(
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) gap,
                  tiles[i],
                ],
              ],
            )
          : Column(
              children: [
                Row(children: [tiles[0], gap, tiles[1]]),
                const SizedBox(height: AppSpacing.md),
                Row(children: [tiles[2], gap, tiles[3]]),
              ],
            ),
    );
  }
}

// How a nutrient reads once its goal is exceeded (KAN-38): amber only when the
// user opted the nutrient into warnings; restrict-type nutrients over are
// neutral information; target-type nutrients — protein, fiber, vitamins,
// minerals — hit their target, which is the goal, so they celebrate.
({Color textColor, Color barColor, String suffix}) _overTreatmentColors(
  NutrientSpec spec,
  Color accent,
  Set<String> warnNutrients,
) {
  switch (overGoalTreatment(spec, warnNutrients)) {
    case OverGoalTreatment.warn:
      return (
        textColor: LuminaHealthColors.warning,
        barColor: LuminaHealthColors.warning,
        suffix: 'over',
      );
    case OverGoalTreatment.neutral:
      return (
        textColor: LuminaHealthColors.onSurfaceVariant,
        barColor: accent,
        suffix: 'over',
      );
    case OverGoalTreatment.celebrate:
      return (textColor: accent, barColor: accent, suffix: '✓');
  }
}

/// One focus nutrient's tile: label + amount, progress toward the goal, and
/// the left/over/incomplete/no-data status line.
class _FocusTile extends StatelessWidget {
  const _FocusTile({
    required this.summary,
    required this.accent,
    required this.warnNutrients,
  });

  final _FocusSummary summary;
  final Color accent;
  final Set<String> warnNutrients;

  @override
  Widget build(BuildContext context) {
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
    final treatment = isOver
        ? _overTreatmentColors(spec, accent, warnNutrients)
        : null;
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

/// The tappable row leading to the full vitamins/minerals breakdown page.
class _ViewFullNutrientsLink extends StatelessWidget {
  const _ViewFullNutrientsLink({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                Icon(Icons.insights, size: 18, color: scheme.primary),
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
                Icon(Icons.chevron_right, color: scheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Daily Logs" section heading with the day's entry count.
class _DailyLogsHeader extends StatelessWidget {
  const _DailyLogsHeader({required this.totalEntries});

  final int totalEntries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
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
            border: Border.all(color: LuminaHealthColors.hairline),
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
