import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth_interceptor.dart';
import '../../ui_components/ui_components.dart';
import '../../ui_system/lumina_health_theme.dart';
import '../../ui_system/tokens.dart';
import 'add_food_page.dart';
import 'data/api_exceptions.dart';
import 'data/fatsecret_client.dart';
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
import 'widgets/amount_sheet.dart' show mealTypeAccent, mealTypeIcon;
import 'widgets/focus_nutrients_card.dart';
import 'widgets/meal_detail_sheet.dart';
import 'widgets/today_date_bar.dart';
import 'widgets/today_hero.dart';
import 'widgets/today_meal_cards.dart';

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
    this.fatsecretApi,
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

  /// Restaurant/chain search source (KAN-67). Like every service param on
  /// this page, null means "construct the real client" — nothing upstream
  /// (main.dart, MainShell) builds one, so the default here is what turns
  /// the feature on in production. Tests inject a fake; to disable the leg
  /// outright, [AddFoodPage.fatsecretApi] is the null-means-off seam.
  final FatSecretClient? fatsecretApi;

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
  late final FatSecretClient _fatsecretApi;

  NutritionDayLog? _dayLog;
  // The locally known day before the selected one, feeding the empty-meal
  // "copy yesterday" shortcut (KAN-51). Null hides the shortcut.
  NutritionDayLog? _previousDayLog;
  // Meals with a copy currently in flight. Every copy mints fresh client
  // uuids (KAN-28: a copy must never reuse identity), so the repository has
  // nothing to dedupe on — a second tap mid-copy would double the whole
  // meal. Membership hides the shortcut and blocks re-entry until the copy
  // (and the reload after it) finishes.
  final Set<MealType> _copyingMeals = {};
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
    _fatsecretApi =
        widget.fatsecretApi ??
        FatSecretClient(
          accessToken: widget.accessToken,
          authInterceptor: widget.authInterceptor,
        );
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

  /// Logs out. The local store is deliberately kept (KAN-64): it's namespaced
  /// per user id, so an unsynced offline outbox survives a re-login instead
  /// of being lost, and can never replay into another account.
  Future<void> _handleLogout() async {
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
      _fatsecretApi.updateToken(widget.accessToken);
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
    unawaited(_loadPreviousDay(date));

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

  /// Reads the locally known state of the day before [date] so empty meal
  /// sections can offer the one-tap repeat shortcut (KAN-51). Local-only and
  /// best-effort: a store miss just hides the shortcut.
  Future<void> _loadPreviousDay(DateTime date) async {
    final prev = DateTime(date.year, date.month, date.day - 1);
    try {
      final log = await _repository.readCachedDay(prev);
      if (!mounted || date != _selectedDate) return;
      setState(() => _previousDayLog = log);
    } catch (_) {
      // Non-critical shortcut — never let it break the page.
    }
  }

  /// The previous day's entries for [meal] that can be re-logged as-is. The
  /// offline-first create path needs a server-resolved food id, so entries
  /// without one (never-synced foods) are skipped.
  List<NutritionEntry> _copyableFromPreviousDay(MealType meal) {
    final entries = _previousDayLog?.meals[meal.wireName] ?? const [];
    return [
      for (final entry in entries)
        if (entry.foodItem.backendId != null) entry,
    ];
  }

  /// One-tap repeat of the previous day's [meal] into the selected day
  /// (KAN-51). Each copy is a brand-new entry (fresh client uuid, same food
  /// and amount) created through the normal offline-first path, so it queues
  /// via the outbox like any other write.
  Future<void> _copyMealFromPreviousDay(MealType meal) async {
    // A stale frame can still deliver a tap after the copy started (the
    // rebuild that hides the shortcut hasn't rendered yet) — ignore it.
    if (_copyingMeals.contains(meal)) return;
    final source = _copyableFromPreviousDay(meal);
    if (source.isEmpty) return;
    final date = _selectedDate;
    final messenger = ScaffoldMessenger.of(context);
    final created = <NutritionEntry>[];
    setState(() => _copyingMeals.add(meal));
    try {
      try {
        for (final entry in source) {
          final at = entry.consumedAt.toLocal();
          created.add(
            await _repository.createEntry(
              food: entry.foodItem,
              mealType: meal.wireName,
              quantityG: entry.quantityG,
              // Same wall-clock time on the target day, so the copy stays in
              // the meal window it came from.
              consumedAt: DateTime(
                date.year,
                date.month,
                date.day,
                at.hour,
                at.minute,
              ),
            ),
          );
        }
      } on ApiException catch (error) {
        if (error.isUnauthorized) {
          await _handleLogout();
          return;
        }
        // Entries copied before the failure stay logged; the reload below
        // shows exactly what made it.
      }
      unawaited(_refreshPendingSync());
      if (!mounted) return;
      await _loadDay();
    } finally {
      // Only after the reload: until _dayLog reflects the copies the meal
      // still looks empty, and releasing earlier would re-arm the shortcut.
      if (mounted) {
        setState(() => _copyingMeals.remove(meal));
      } else {
        _copyingMeals.remove(meal);
      }
    }
    if (!mounted || created.isEmpty) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          created.length == 1
              ? 'Copied 1 food'
              : 'Copied ${created.length} foods',
        ),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _undoCopy(created),
        ),
      ),
    );
  }

  /// Undo of a meal copy: deletes the freshly created entries. Copies whose
  /// create is still queued are simply forgotten; synced ones get tombstoned
  /// like any other delete.
  Future<void> _undoCopy(List<NutritionEntry> created) async {
    try {
      for (final entry in created) {
        await _repository.deleteEntry(entry);
      }
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await _handleLogout();
        return;
      }
    }
    unawaited(_refreshPendingSync());
    if (mounted) await _loadDay();
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
    List<StagedFood> initialItems = const [],
    DateTime? targetDate,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final date = targetDate ?? _selectedDate;
    // When opened from the generic "+" (no explicit meal), guess the meal from
    // the time of day and what's already been logged today.
    final meal =
        initialMeal ??
        suggestMealType(
          now: DateTime.now(),
          mealsLogged: _dayLog?.meals ?? const {},
          windows: _mealWindows,
        );
    // The pop result only reports a clean submit; a partially failed one
    // (KAN-53) has already created entries before the page is backed out,
    // so track creations separately — the day jump below must fire for
    // those too or the logged copies end up off-screen.
    var loggedAny = false;
    final didAdd = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddFoodPage(
          localDb: _localDb,
          foodsApi: _foodsApi,
          repository: _repository,
          offClient: _offClient,
          fatsecretApi: _fatsecretApi,
          onLogout: _handleLogout,
          selectedDate: date,
          initialMeal: meal,
          initialItems: initialItems,
          focusSpecs: _focusSpecs,
          catalog: _catalog,
          warnNutrients: _warnNutrients,
          onEntryLogged: () => loggedAny = true,
        ),
      ),
    );
    if (!mounted) return;
    // A duplicate targets today no matter which day was being browsed; jump
    // there whenever anything was logged so the freshly logged copies are
    // on screen.
    if (loggedAny && !DateUtils.isSameDay(_selectedDate, date)) {
      setState(() => _selectedDate = date);
    }
    // Reload even when nothing was logged: a no-op refetch when unchanged.
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

  Future<void> _openMealDetails(BuildContext context, MealSummary meal) async {
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
        mealColor: meal.color,
        entries: meal.entries,
        focusSpecs: _focusSpecs,
        catalog: _catalog,
        warnNutrients: _warnNutrients,
        onUpdateEntry: (entry, {quantityG, mealType}) =>
            _updateEntry(entry, quantityG: quantityG, mealType: mealType),
        onDeleteEntry: (entry) => _deleteEntry(entry),
        onRestoreEntry: (entry) => _restoreEntry(entry),
        onViewFoodDetails: _openFoodDetail,
        onAddMore: () {
          Navigator.of(context).pop();
          _openAddFoodSheet(context, initialMeal: meal.mealType);
        },
        // Duplicate stages the meal's foods into a fresh add-food session
        // targeting *today* — the "eat this again" case — so a meal browsed
        // on any past day can be re-logged (and tweaked) in one flow.
        // Nothing is written until Log is pressed there.
        onDuplicate: (entries) {
          Navigator.of(context).pop();
          _openAddFoodSheet(
            context,
            initialMeal: meal.mealType,
            initialItems: [
              for (final entry in entries)
                (item: entry.foodItem, grams: entry.quantityG),
            ],
            targetDate: DateUtils.dateOnly(DateTime.now()),
          );
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

  Future<void> _openNutrientDetail(BuildContext context) async {
    final entries =
        _dayLog?.meals.values.expand((list) => list).toList() ??
        const <NutritionEntry>[];
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NutritionDetailPage(
          dateLabel: _dateLabel(),
          eatenKcal: displayKcalTotal(entries),
          entries: entries,
          serverNutrients: _dayLog?.nutrients,
          nutrientGoals: widget.preferences?.nutrientGoals,
          warnNutrients: _warnNutrients,
          // Lets the nutrient sheet's "no data" rows open the read-first food
          // page so the user can fill the gap (KAN-92).
          onEditFood: _openFoodDetail,
        ),
      ),
    );
    // Reload after the detail page pops: a food edited from the nutrient sheet
    // changes this day's kcal/nutrients server-side. A no-op refetch otherwise.
    if (!mounted) return;
    await _loadDay();
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

  /// Undo of a swipe-delete (KAN-39): re-creates the entry through the
  /// offline-first path, keeping its uuid identity. Null means it failed.
  Future<NutritionEntry?> _restoreEntry(NutritionEntry entry) async {
    try {
      final restored = await _repository.restoreEntry(entry);
      unawaited(_refreshPendingSync());
      return restored;
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await _handleLogout();
        return null;
      }
      return null;
    }
  }

  /// One summary per focus nutrient, in the user's chosen order. Amounts come
  /// from the server's per-day nutrients map; the classic macros fall back to
  /// the totals block (older cached payloads lack the map), and anything else
  /// falls back to a client-side aggregate over the day's entries. A null
  /// amount means foods were logged but none reported the nutrient ("no data");
  /// an empty day reads as a plain 0 so a fresh morning isn't full of dashes.
  List<FocusSummary> _buildFocusSummaries(NutritionTotals? totals) {
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
          return FocusSummary(
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

  List<MealSummary> _buildMealSummaries() {
    final Map<String, List<NutritionEntry>> meals = _dayLog?.meals ?? {};
    return [
      for (final meal in MealType.values)
        MealSummary(
          name: meal.label,
          mealType: meal,
          icon: mealTypeIcon(meal),
          color: mealTypeAccent(meal),
          entries: meals[meal.wireName] ?? const [],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final totals = _dayLog?.totals;
    // Derived from the entries, not totals.kcal: the ring must equal the sum
    // of the meal cards, which round per entry (KAN-99).
    final eatenKcal = displayKcalTotal(
      _dayLog?.meals.values.expand((list) => list) ?? const <NutritionEntry>[],
    );
    final int? burnedKcal = _burnedKcal;
    // Exercise adds to the day's budget; "remaining" can go negative, which
    // we surface as an over-budget amount rather than clamping to zero.
    final int kcalBudget = _calorieGoal + (burnedKcal ?? 0);
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
              // Manual re-sync after connectivity returns (KAN-55). The
              // always-scrollable physics keep the gesture available even
              // when the day's content fits on one screen.
              child: RefreshIndicator(
                onRefresh: _loadDay,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
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
                    TodayDateBar(
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
                        child: PendingSyncChip(count: _pendingSyncCount),
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
                            actionLabel: 'Retry',
                            onAction: _loadDay,
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
                        child: TodayHeroSection(
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
                        child: FocusNutrientsCard(
                          summaries: focusSummaries,
                          warnNutrients: _warnNutrients,
                        ),
                      ),
                    ),
                    // Full nutrient breakdown entry point
                    SliverToBoxAdapter(
                      child: ViewFullNutrientsLink(
                        onTap: () => _openNutrientDetail(context),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: DailyLogsHeader(totalEntries: totalEntries),
                    ),
                    SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final meal = mealSummaries[index];
                        final canCopy =
                            meal.entries.isEmpty &&
                            !_copyingMeals.contains(meal.mealType) &&
                            _copyableFromPreviousDay(meal.mealType).isNotEmpty;
                        return Padding(
                          padding: EdgeInsets.fromLTRB(
                            AppSpacing.lg,
                            index == 0 ? 0 : AppSpacing.md,
                            AppSpacing.lg,
                            0,
                          ),
                          child: TodayMealCard(
                            meal: meal,
                            onTap: () => _openMealDetails(context, meal),
                            onAddFood: () => _openAddFoodSheet(
                              context,
                              initialMeal: meal.mealType,
                            ),
                            onCopyPreviousDay: canCopy
                                ? () => _copyMealFromPreviousDay(meal.mealType)
                                : null,
                            copyPreviousDayLabel: isToday
                                ? 'Copy from yesterday'
                                : 'Copy from previous day',
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
            ),
          ],
        ),
      ),
    );
  }
}

/// Burned-kcal source (KAN-37). Null means no activity tracking is configured,
/// which hides the BURNED stat entirely — a permanently-zero figure reads as
/// broken. When an activity integration lands, supply its value here and the
/// stat re-enables with no layout rework.
const int? _burnedKcal = null;
