import 'dart:async';
import 'dart:math' show max, min;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import '../../ui_components/ui_components.dart';
import '../../ui_system/lumina_health_theme.dart';
import '../../ui_system/tokens.dart';
import 'custom_food_page.dart';
import 'data/api_exceptions.dart';
import 'data/fatsecret_client.dart';
import 'data/fatsecret_mapper.dart';
import 'data/food_local_db.dart';
import 'data/food_models.dart';
import 'data/food_sync.dart';
import 'data/foods_api_service.dart';
import 'data/nutrient_catalog.dart';
import 'data/nutrition_repository.dart';
import 'data/off_client.dart';
import 'data/off_image_downloader.dart';
import 'data/off_mapper.dart';
import 'data/off_rate_limiter.dart';
import 'food_detail_page.dart';
import 'food_search_results.dart';
import 'live_search_controller.dart';
import 'nutrition_scan_page.dart';
import 'widgets/amount_sheet.dart';
import 'widgets/nutrient_breakdown_view.dart' show formatNutrientValue;
import 'widgets/swipe_delete_background.dart';

/// FatSecret's free-tier attribution link (KAN-67 legal requirement).
const String kFatSecretAttributionUrl = 'https://platform.fatsecret.com';

const String _filterRecent = 'Recent';
const String _filterFavorites = 'Favorites';

/// One food pre-staged into the page: the item plus the grams to stage it
/// at. The duplicate-meal flow hands a meal's foods over in this shape, each
/// at the amount it was originally logged with.
typedef StagedFood = ({FoodItem item, double grams});

class AddFoodPage extends StatefulWidget {
  const AddFoodPage({
    super.key,
    required this.localDb,
    required this.foodsApi,
    required this.repository,
    required this.offClient,
    this.fatsecretApi,
    required this.onLogout,
    required this.selectedDate,
    this.initialMeal,
    this.initialItems = const [],
    this.focusSpecs,
    this.catalog,
    this.warnNutrients = const {},
    this.onEntryLogged,
    this.scanBarcode,
  });

  final FoodLocalDb localDb;
  final FoodsApiService foodsApi;
  final NutritionRepository repository;
  final OffClient offClient;

  /// Restaurant/chain search source (KAN-67). Null disables the whole
  /// FatSecret leg — live search, merge, enrich, attribution footer — so
  /// every existing test-construction site keeps compiling unchanged.
  final FatSecretClient? fatsecretApi;
  final Future<void> Function() onLogout;
  final DateTime selectedDate;
  final MealType? initialMeal;

  /// Foods staged before the page opens (duplicate meal): each lands in the
  /// Added list at its given amount, ready to tweak or log as-is. Nothing is
  /// written until the user submits.
  final List<StagedFood> initialItems;

  /// The user's focus nutrients (goal-resolved, in display order), driving the
  /// summary card and the amount sheet's preview pills so this page tracks the
  /// same nutrients as the today page. Null falls back to the default trio.
  final List<NutrientSpec>? focusSpecs;

  /// The full goal-resolved catalog, forwarded to the food detail page so its
  /// per-100g targets match the today page. Null falls back to the defaults.
  final List<NutrientSpec>? catalog;

  /// Catalog keys the user opted into over-goal warnings for (KAN-38),
  /// forwarded to the amount sheet's nutrition-facts breakdown.
  final Set<String> warnNutrients;

  /// Fires once per staged item actually logged during submit. A mid-list
  /// failure (KAN-53) leaves the page open with the earlier items already
  /// created, so the pop result alone can't tell the caller whether
  /// [selectedDate] gained entries — backing out after a partial submit
  /// must still surface them.
  final VoidCallback? onEntryLogged;

  /// Runs the barcode-scan flow and resolves with the scanned code (null =
  /// dismissed). Defaults to pushing [NutritionScanPage]; tests inject a fake
  /// since the camera scanner needs platform channels.
  final Future<String?> Function(BuildContext context)? scanBarcode;

  @override
  State<AddFoodPage> createState() => _AddFoodPageState();
}

class _AddFoodPageState extends State<AddFoodPage> {
  final TextEditingController _searchController = TextEditingController();
  final OffMapper _offMapper = OffMapper();
  final FatSecretMapper _fatsecretMapper = FatSecretMapper();
  final OffImageDownloader _imageDownloader = OffImageDownloader();
  late final LiveSearchController _liveSearch;
  Timer? _rateLimitTicker;

  static const Duration _scanCooldown = Duration(seconds: 3);

  // Whole seconds left on each online budget's pause (KAN-96); 0 = free.
  // Counted down by the once-per-second [_rateLimitTicker] rather than
  // recomputed from a wall-clock deadline, so widget tests can drive the
  // countdown with pumped fake time. The two budgets stay separate on purpose:
  // OFF's pause also gates the barcode-scan and enrich paths, FatSecret's must
  // not. Held in a notifier only the banner listens to, so a tick rebuilds
  // that one line instead of this whole page (KAN-124); the page itself
  // rebuilds only when OFF's blocked state flips.
  final ValueNotifier<_RateLimitCountdown> _rateLimit = ValueNotifier(
    const _RateLimitCountdown(),
  );
  String? _lastScannedBarcode;
  DateTime? _lastScannedAt;

  late MealType _selectedMeal = widget.initialMeal ?? MealType.breakfast;
  late final List<NutrientSpec> _focusSpecs =
      widget.focusSpecs ?? resolveFocusSpecs(null);
  String _selectedFilter = _filterRecent;

  // Result key currently being enriched via an OFF fetch (shows a card spinner).
  String? _enrichingKey;

  // Track actual items (with their per-item amount) instead of search indices
  final List<_AddedFood> _addedItems = [];

  bool _isBackendLoading = false;
  bool _isOffLoading = false;
  bool _isFatSecretLoading = false;
  bool _isSubmitting = false;
  bool _ignoreSearchChange = false;

  String? _message;
  InlineBannerTone? _messageTone;

  List<FoodItem> _localResults = [];
  List<FoodItem> _backendResults = [];
  List<FoodItem> _offResults = [];
  List<FoodItem> _fatsecretResults = [];

  @override
  void initState() {
    super.initState();
    // A staged item's identity is its result key, and every staged-list
    // operation resolves through it — so a food logged as two entries in the
    // source meal must seed one merged row (summed grams), not two rows
    // fighting over the same key.
    for (final seed in widget.initialItems) {
      final existing = _indexOfAdded(seed.item);
      if (existing >= 0) {
        _addedItems[existing] = _AddedFood(
          item: _addedItems[existing].item,
          grams: _addedItems[existing].grams + seed.grams,
        );
      } else {
        _addedItems.add(_AddedFood(item: seed.item, grams: seed.grams));
      }
    }
    // The controller owns the shared 600ms debounce + per-query CancelToken +
    // 2-char floor (D-06/D-07/D-08). The page hands it `setState`-driven setters
    // so debounced backend/OFF results flow back into the existing merge fields.
    _liveSearch = LiveSearchController(
      offClient: widget.offClient,
      foodsApi: widget.foodsApi,
      offMapper: _offMapper,
      fatsecretClient: widget.fatsecretApi,
      fatsecretMapper: _fatsecretMapper,
      onBackendResults: (results) {
        if (!mounted) return;
        setState(() => _backendResults = results);
      },
      onOffResults: (results) {
        if (!mounted) return;
        setState(() => _offResults = results);
      },
      // Null unless widget.fatsecretApi is set — the controller only fires
      // the leg when both client and callback are non-null (feature off
      // otherwise).
      onFatSecretResults: widget.fatsecretApi == null
          ? null
          : (results) {
              if (!mounted) return;
              setState(() => _fatsecretResults = results);
            },
      onLoadingChanged:
          ({
            required bool backend,
            required bool off,
            required bool fatsecret,
          }) {
            if (!mounted) return;
            setState(() {
              _isBackendLoading = backend;
              _isOffLoading = off;
              _isFatSecretLoading = fatsecret;
            });
          },
      // Budget-exhausted hits from the debounced live legs raise the same
      // paused notice as the scan/enrich paths (KAN-96) — otherwise typing
      // during a block would look like the search simply found nothing new.
      onOffRateLimited: _applyOffLimit,
      onFatSecretRateLimited: _applyFatSecretLimit,
      onUnauthorized: widget.onLogout,
    );
    _searchController.addListener(_handleSearchChange);
    _loadFilterResults();
  }

  @override
  void dispose() {
    _liveSearch.dispose();
    _rateLimitTicker?.cancel();
    _rateLimit.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool get _isOffRateLimited => _rateLimit.value.offSeconds > 0;

  void _applyOffLimit(Duration retryAfter) =>
      _applyRateLimit(retryAfter, isOff: true);

  void _applyFatSecretLimit(Duration retryAfter) =>
      _applyRateLimit(retryAfter, isOff: false);

  /// Starts (or re-syncs) one budget's pause. Every throttle hit lands here —
  /// live search, barcode scan, enrich-on-tap — so re-applying with the
  /// limiter's freshest retry-after keeps the countdown honest even when the
  /// window shrinks as old call timestamps age out.
  void _applyRateLimit(Duration retryAfter, {required bool isOff}) {
    if (!mounted || retryAfter <= Duration.zero) return;
    final seconds = (retryAfter.inMilliseconds / 1000).ceil();
    final current = _rateLimit.value;
    _setRateLimit(
      isOff
          ? current.copyWith(offSeconds: seconds)
          : current.copyWith(fatsecretSeconds: seconds),
    );
    // One ticker serves both budgets: it live-updates the banner countdown
    // and flips the blocked state (scan button, enrich gate, banner) back
    // the moment a window elapses.
    _rateLimitTicker ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _onRateLimitTick(),
    );
  }

  void _onRateLimitTick() {
    if (!mounted) return;
    final next = _rateLimit.value.tick();
    _setRateLimit(next);
    if (!next.isActive) {
      _rateLimitTicker?.cancel();
      _rateLimitTicker = null;
    }
  }

  /// Publishes [next] to the banner, and rebuilds the page only when OFF's
  /// blocked state flips — that's all the page itself reads (scan button,
  /// enrich gate); the per-second countdown text is the banner's own concern.
  void _setRateLimit(_RateLimitCountdown next) {
    final offFlipped = (next.offSeconds > 0) != _isOffRateLimited;
    if (offFlipped) {
      setState(() => _rateLimit.value = next);
    } else {
      _rateLimit.value = next;
    }
  }

  void _handleSearchChange() {
    if (_ignoreSearchChange) return;
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      // Clear pending online work and reset the result fields, then fall back
      // to the recent/favorites list.
      _liveSearch.onQueryChanged('');
      setState(() {
        _backendResults = [];
        _offResults = [];
        _fatsecretResults = [];
        _message = null;
        _messageTone = null;
        _isBackendLoading = false;
        _isOffLoading = false;
        _isFatSecretLoading = false;
      });
      _loadFilterResults();
      return;
    }

    setState(() {
      _offResults = [];
      _backendResults = [];
      _fatsecretResults = [];
      _message = null;
      _messageTone = null;
    });
    // Local cache stays instant + un-debounced (D-06); the controller owns the
    // shared 600ms debounce that fires backend typeahead + OFF together.
    _loadLocalSearch(query);
    _liveSearch.onQueryChanged(query);
  }

  Future<void> _loadFilterResults() async {
    final query = _searchController.text.trim();
    if (query.isNotEmpty) return;
    final results = _selectedFilter == _filterFavorites
        ? await widget.localDb.fetchFavorites()
        : await widget.localDb.fetchRecentFoods();
    if (!mounted) return;
    setState(() {
      _localResults = results;
    });
  }

  Future<void> _loadLocalSearch(String query) async {
    final results = await widget.localDb.searchFoods(query);
    if (!mounted) return;
    setState(() {
      _localResults = results;
    });
  }

  void _selectMeal(MealType meal) {
    setState(() {
      _selectedMeal = meal;
    });
  }

  void _selectFilter(String filter) {
    if (_selectedFilter == filter) return;
    setState(() {
      _selectedFilter = filter;
    });
    _loadFilterResults();
  }

  int _indexOfAdded(FoodItem item) {
    final key = foodResultKey(item);
    if (key == null) return -1;
    for (var i = 0; i < _addedItems.length; i++) {
      if (foodResultKey(_addedItems[i].item) == key) return i;
    }
    return -1;
  }

  bool _isAdded(FoodItem item) => _indexOfAdded(item) >= 0;

  double _defaultGramsFor(FoodItem item) {
    final learnedGrams = item.lastLoggedGrams;
    if (item.sameAmountStreak >= 2 && learnedGrams != null) {
      return learnedGrams;
    }
    // Prefer one whole piece (an egg, a burger), then one serving, then 100 g.
    final piece = item.gramsPerPiece;
    if (piece != null && piece > 0) return piece;
    final serving = item.servingSizeG;
    if (serving != null && serving > 0) return serving;
    // For cooked-basis foods the natural default is 100 g *raw* (what the
    // scale shows for a product sold uncooked), stored as cooked-equivalent
    // grams like every logged amount.
    return item.isCookedBasis ? 100.0 * kCookedYieldFactor : 100.0;
  }

  // OFF text search can't return serving data, so an OFF result starts without a
  // serving/piece size. Fetch the full product the moment it's tapped so the
  // amount sheet can offer pieces/servings and the quick-add default is sane.
  // FatSecret's search is the same story (no serving data), but it has its
  // own throttle — never gated on `_isOffRateLimited`, which is OFF's budget.
  bool _needsEnrich(FoodResult result) {
    if (result.origin == FoodResultOrigin.off) {
      return result.item.barcode != null &&
          result.item.barcode!.isNotEmpty &&
          result.item.servingSizeG == null &&
          !_isOffRateLimited;
    }
    if (result.origin == FoodResultOrigin.fatsecret) {
      return result.item.servingSizeG == null && widget.fatsecretApi != null;
    }
    return false;
  }

  Future<FoodItem> _enrich(FoodItem item) async {
    if (item.source == fatsecretSource) {
      final api = widget.fatsecretApi;
      if (api == null) return item;
      try {
        final food = await api.getFood(item.externalId);
        if (food == null || !mounted) return item;
        return _fatsecretMapper.mapDetail(food) ?? item;
      } on OffRateLimitException catch (error) {
        // FatSecret's own throttle — deliberately not routed through
        // `_applyOffLimit` (that would block the OFF barcode-scan path over
        // a FatSecret budget exhaustion, two unrelated concerns); it raises
        // the FatSecret-side paused notice instead (KAN-96).
        _applyFatSecretLimit(error.retryAfter);
        return item;
      } on ApiException catch (error) {
        // Unlike the OFF branch below, this enrich crosses our authenticated
        // proxy. A surfaced 401 means the interceptor's token refresh already
        // failed — route to logout like every other backend call site instead
        // of dressing a dead session up as "no nutrition data".
        if (error.isUnauthorized) {
          await widget.onLogout();
        }
        return item;
      }
    }
    final barcode = item.barcode;
    if (barcode == null || barcode.isEmpty) return item;
    try {
      final response = await widget.offClient.fetchProduct(barcode);
      if (response == null || !mounted) return item;
      final locale = Localizations.localeOf(context).languageCode;
      return _offMapper.mapProduct(
        product: response.product,
        rawJson: response.rawJson,
        localeLanguage: locale,
      );
    } on OffRateLimitException catch (error) {
      _applyOffLimit(error.retryAfter);
      return item;
    } on OffException {
      return item;
    }
  }

  // One-tap quick add: a repeated amount wins after two matching logs;
  // otherwise the smart default remains 1 piece/serving when known, else
  // 100 g. The amount can be fine-tuned later by tapping the Added item. A
  // second result tap toggles it off silently: that tap is deliberate, unlike
  // an accidental swipe, so haptic acknowledgement is enough without a noisy
  // Undo snackbar. OFF results are enriched first (a short fetch) so an
  // unlearned default lands on a whole piece/serving rather than a raw 100 g.
  Future<void> _onResultTap(FoodResult result) async {
    FocusScope.of(context).unfocus();
    // Shadowed globals are normally hidden, but this also keeps a stale result
    // tap from staging a global beside its forked personal override.
    final existingIndex = _stagedIndexOf(result.item);
    if (existingIndex >= 0) {
      unawaited(HapticFeedback.selectionClick());
      setState(() => _addedItems.removeAt(existingIndex));
      return;
    }

    var item = result.item;
    final wasFatSecretEnrich =
        _needsEnrich(result) && result.origin == FoodResultOrigin.fatsecret;
    if (_needsEnrich(result)) {
      final key = foodResultKey(item);
      if (key == null || _enrichingKey != null) return;
      setState(() => _enrichingKey = key);
      item = await _enrich(item);
      if (!mounted) return;
      setState(() => _enrichingKey = null);
      // This callback began as an add; an enrich race must not reinterpret the
      // same tap as a removal after another path stages the resolved identity.
      if (_stagedIndexOf(item) >= 0) return;
    }

    // A FatSecret item whose enrich fetch found no per-100g-mappable serving
    // (see FatSecretMapper.mapDetail) carries no nutrition at all — quick-add
    // would silently stage a zero-calorie phantom that corrupts the day's
    // totals, so refuse and tell the user instead of adding it.
    if (wasFatSecretEnrich &&
        item.kcal100g == null &&
        item.nutrimentsJson == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('No nutrition data available for this item.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
      return;
    }

    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _addedItems.add(_AddedFood(item: item, grams: _defaultGramsFor(item)));
    });
  }

  Future<void> _editAddedItem(int index) async {
    final entry = _addedItems[index];
    final result = await showAmountSheet(
      context: context,
      item: entry.item,
      initialGrams: entry.grams,
      isEditing: true,
      focusSpecs: _focusSpecs,
      catalog: widget.catalog ?? kNutrientCatalog,
      warnNutrients: widget.warnNutrients,
      onViewDetails: _openFoodDetail,
    );
    if (result == null || !mounted) return;
    // While the sheet was open, its View Details flow may have removed the
    // staged entry (custom-food delete / override revert) or swapped it for
    // a fresh override under a different key — the integer index is stale.
    // Re-resolve by identity; if the entry is gone, there is nothing to edit.
    final liveIndex = _stagedIndexOf(entry.item);
    if (liveIndex < 0) return;
    if (result.removed) {
      _removeAddedItem(liveIndex);
      return;
    }
    setState(() {
      if (result.grams != null) {
        _addedItems[liveIndex] = _AddedFood(
          item: _addedItems[liveIndex].item,
          grams: result.grams!,
        );
      }
    });
  }

  /// Where [item]'s staged entry lives *now*: under its own key, or — when a
  /// detail-page edit forked it into a personal override — under the custom
  /// food that _applyCustomFoodUpdate swapped into its slot.
  int _stagedIndexOf(FoodItem item) {
    final direct = _indexOfAdded(item);
    if (direct >= 0) return direct;
    for (var i = 0; i < _addedItems.length; i++) {
      final candidate = _addedItems[i].item;
      final overridesSameFood =
          candidate.isCustom &&
          ((item.backendId != null &&
                  candidate.overridesBackendId == item.backendId) ||
              (item.barcode != null &&
                  item.barcode!.isNotEmpty &&
                  candidate.overridesBarcode == item.barcode));
      if (overridesSameFood) return i;
    }
    return -1;
  }

  /// Drops the staged item at [index] and offers Undo (KAN-39). Staged items
  /// only live in this list, so undo is a plain re-insert at the old spot.
  void _removeAddedItem(int index) {
    final removed = _addedItems[index];
    unawaited(HapticFeedback.mediumImpact());
    setState(() => _addedItems.removeAt(index));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Removed ${removed.item.name}'),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              if (!mounted) return;
              setState(() {
                _addedItems.insert(min(index, _addedItems.length), removed);
              });
            },
          ),
        ),
      );
  }

  // Long-press = inspect (KAN-35): always the read-first detail page, never
  // a mutation or a direct edit form — overrides are created only via the
  // labeled edit action inside it. Serving-less OFF results enrich first so
  // the page doesn't open on sparse per-100g data.
  Future<void> _onResultLongPress(FoodResult result) async {
    FocusScope.of(context).unfocus();
    var item = result.item;
    if (_needsEnrich(result)) {
      final key = foodResultKey(item);
      if (key == null || _enrichingKey != null) return;
      setState(() => _enrichingKey = key);
      item = await _enrich(item);
      if (!mounted) return;
      setState(() => _enrichingKey = null);
    }
    await _openFoodDetail(item);
  }

  /// Pushes the read-first food detail page (KAN-33). Edits made there are
  /// propagated into this page's lists as they happen; resolves with the
  /// updated item (or null if nothing changed) so the amount sheet can
  /// refresh its preview.
  Future<FoodItem?> _openFoodDetail(FoodItem item) {
    FocusScope.of(context).unfocus();
    return pushFoodDetailPage(
      context,
      item: item,
      foodsApi: widget.foodsApi,
      localDb: widget.localDb,
      onLogout: widget.onLogout,
      catalog: widget.catalog ?? kNutrientCatalog,
      onItemChanged: _applyCustomFoodUpdate,
      onItemReverted: _applyCustomFoodRemoval,
    );
  }

  /// Reflects a saved custom food everywhere it can appear: its own rows in
  /// the results/Added lists and — for overrides — any staged copy of the
  /// global it shadows. A fresh fork not yet in any list is surfaced in the
  /// local results, standing in for the shadowed global that mergeFoodResults
  /// hides.
  void _applyCustomFoodUpdate(FoodItem stored) {
    bool isSelf(FoodItem candidate) =>
        candidate.isCustom && candidate.externalId == stored.externalId;
    bool isShadowedGlobal(FoodItem candidate) =>
        stored.isOverride &&
        !candidate.isCustom &&
        ((candidate.backendId != null &&
                candidate.backendId == stored.overridesBackendId) ||
            (candidate.barcode != null &&
                candidate.barcode!.isNotEmpty &&
                candidate.barcode == stored.overridesBarcode));
    bool matches(FoodItem candidate) =>
        isSelf(candidate) || isShadowedGlobal(candidate);

    List<FoodItem> swap(List<FoodItem> list) => [
      for (final it in list) matches(it) ? stored : it,
    ];

    setState(() {
      for (var i = 0; i < _addedItems.length; i++) {
        if (matches(_addedItems[i].item)) {
          _addedItems[i] = _AddedFood(
            item: stored,
            grams: _addedItems[i].grams,
          );
        }
      }
      _localResults = swap(_localResults);
      _backendResults = swap(_backendResults);
      if (!_localResults.any(isSelf) && !_backendResults.any(isSelf)) {
        _localResults = [stored, ..._localResults];
      }
    });
  }

  /// Drops a deleted/reverted custom food from every list on this page.
  void _applyCustomFoodRemoval(FoodItem item) {
    bool matches(FoodItem candidate) =>
        candidate.isCustom && candidate.externalId == item.externalId;
    setState(() {
      _addedItems.removeWhere((added) => matches(added.item));
      _localResults = [
        for (final it in _localResults)
          if (!matches(it)) it,
      ];
      _backendResults = [
        for (final it in _backendResults)
          if (!matches(it)) it,
      ];
    });
  }

  // Opens the create-food form; the popped draft is stored and staged before
  // its best-effort background sync. _submitItems re-syncs anything still
  // missing a backendId.
  Future<void> _openCustomFoodPage() async {
    FocusScope.of(context).unfocus();
    final result = await Navigator.of(context).push<CustomFoodResult>(
      MaterialPageRoute(builder: (_) => const CustomFoodPage()),
    );
    final draft = result?.item;
    if (draft == null || !mounted) return;
    final stored = await saveCustomFoodDraft(
      draft,
      foodsApi: widget.foodsApi,
      localDb: widget.localDb,
      onUnauthorized: widget.onLogout,
      onSynced: (synced) {
        if (mounted) _applyCustomFoodUpdate(synced);
      },
    );
    if (stored == null || !mounted) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _addedItems.add(
        _AddedFood(item: stored, grams: _defaultGramsFor(stored)),
      );
    });
  }

  Future<void> _openScanPage() async {
    FocusScope.of(context).unfocus();
    final scan =
        widget.scanBarcode ??
        (context) => Navigator.of(context).push<String>(
          MaterialPageRoute(builder: (_) => const NutritionScanPage()),
        );
    final barcode = await scan(context);
    if (barcode == null || barcode.trim().isEmpty) return;
    await _handleBarcodeScan(barcode.trim());
  }

  /// Puts [barcode] into the search field without triggering the live-search
  /// listener — the scan flow supplies its own result below.
  void _setSearchTextSilently(String barcode) {
    _ignoreSearchChange = true;
    _searchController.text = barcode;
    _searchController.selection = TextSelection.collapsed(
      offset: _searchController.text.length,
    );
    _ignoreSearchChange = false;
  }

  Future<void> _handleBarcodeScan(String barcode) async {
    if (_isOffRateLimited) {
      // Only reachable when the block landed while the scanner was already
      // open (the scan button itself is disabled during a pause). The pinned
      // countdown notice (KAN-96) is guaranteed visible, so it explains the
      // dropped scan without an extra message.
      return;
    }
    // Debounce re-scans of the same package: the camera fires repeatedly
    // while the barcode stays in frame.
    final now = DateTime.now();
    if (_lastScannedBarcode == barcode &&
        _lastScannedAt != null &&
        now.difference(_lastScannedAt!) < _scanCooldown) {
      return;
    }
    _lastScannedBarcode = barcode;
    _lastScannedAt = now;
    // The user's override shadows the catalog product: a scan of the
    // original's barcode resolves straight to their corrected copy.
    final override = await widget.localDb.fetchOverrideForBarcode(barcode);
    if (!mounted) return;
    if (override != null) {
      _setSearchTextSilently(barcode);
      setState(() {
        _localResults = [override];
        _backendResults = [];
        _offResults = [];
        _fatsecretResults = [];
        _message = null;
        _messageTone = null;
      });
      return;
    }
    await _fetchScannedProduct(barcode);
  }

  /// OFF lookup for a scanned barcode with no local override: shows the
  /// product as the sole result (the user still taps to add), or an inline
  /// banner on miss/error. A throttle raises the pinned countdown notice
  /// instead (KAN-96).
  Future<void> _fetchScannedProduct(String barcode) async {
    setState(() {
      _isOffLoading = true;
      _message = null;
      _messageTone = null;
    });
    try {
      final response = await widget.offClient.fetchProduct(barcode);
      if (!mounted) return;
      if (response == null) {
        setState(() {
          _isOffLoading = false;
          _message = 'No product found for that barcode.';
          _messageTone = InlineBannerTone.info;
        });
        return;
      }
      final locale = Localizations.localeOf(context).languageCode;
      final item = _offMapper.mapProduct(
        product: response.product,
        rawJson: response.rawJson,
        localeLanguage: locale,
      );
      if (!mounted) return;
      _setSearchTextSilently(barcode);
      setState(() {
        _offResults = [item];
        _backendResults = [];
        _localResults = [];
        _fatsecretResults = [];
        _isOffLoading = false;
        // Auto add scanned item? Maybe not, let user tap it.
      });
    } on OffRateLimitException catch (error) {
      if (!mounted) return;
      // The pinned countdown notice (KAN-96) explains the pause; a static
      // banner message here would only go stale as the window counts down.
      _applyOffLimit(error.retryAfter);
      setState(() {
        _isOffLoading = false;
      });
    } on OffException catch (error) {
      if (!mounted) return;
      setState(() {
        _isOffLoading = false;
        _message = error.message;
        _messageTone = InlineBannerTone.error;
      });
    }
  }

  Future<FoodItem?> _tryUploadImages(FoodItem item) async {
    final backendId = item.backendId;
    final imageUrl = item.imageUrl;
    if (backendId == null || imageUrl == null) return null;
    final result = await _imageDownloader.downloadImage(
      imageUrl,
      useOffRateLimit: item.source == offSource,
    );
    if (result == null) return null;
    return widget.foodsApi.uploadFoodImages(
      foodItemId: backendId,
      bytes: result.bytes,
      contentType: result.contentType,
      imageSignature: item.imageSignature,
    );
  }

  /// Logs one staged item, in named steps: resolve a backend id (custom
  /// upsert vs global ingest/check), best-effort image upload, persist the
  /// food locally, create the entry (optimistic + offline-tolerant, KAN-28),
  /// and touch the recents ordering.
  Future<void> _logOneItem(_AddedFood added, DateTime consumedAt) async {
    FoodItem selected = added.item;
    bool imagesOk = false;
    if (selected.backendId == null) {
      if (selected.isCustom) {
        // Custom foods sync through their owner-scoped upsert, never the
        // OFF ingest/check flow (which rejects the custom source).
        final synced = await widget.foodsApi.upsertCustomFood(selected);
        selected = selected.copyWith(backendId: synced.backendId);
      } else {
        final (resolved, resolvedImagesOk) = await ensureGlobalBackendId(
          selected,
          foodsApi: widget.foodsApi,
        );
        selected = resolved;
        imagesOk = resolvedImagesOk;
      }
    }
    if (selected.backendId == null) {
      throw ApiException('Unable to resolve food item id.');
    }

    if (!imagesOk) {
      // Nice-to-have; never block logging the meal on it (e.g. offline
      // with an already-resolved food).
      try {
        final uploaded = await _tryUploadImages(selected);
        if (uploaded != null) selected = uploaded;
      } on ApiException {
        // Retried the next time this food is logged.
      }
    }

    selected = await widget.localDb.upsertFood(selected);

    await widget.repository.createEntry(
      food: selected,
      mealType: _selectedMeal.wireName,
      quantityG: added.grams,
      consumedAt: consumedAt,
    );

    if (selected.localId != null) {
      await widget.localDb.updateLastUsed(
        selected.localId!,
        consumedAt,
        added.grams,
      );
    }
  }

  Future<void> _submitItems() async {
    if (_addedItems.isEmpty) return;

    setState(() {
      _isSubmitting = true;
      _message = null;
      _messageTone = null;
    });

    final now = DateTime.now();
    final consumedAt = DateTime(
      widget.selectedDate.year,
      widget.selectedDate.month,
      widget.selectedDate.day,
      now.hour,
      now.minute,
    );

    // Each success leaves _addedItems immediately: createEntry mints a fresh
    // client uuid per call, so a retry after a mid-list failure would
    // re-log everything still staged — dedup has to happen here (KAN-53).
    for (final added in List.of(_addedItems)) {
      try {
        await _logOneItem(added, consumedAt);
      } on ApiException catch (error) {
        if (error.isUnauthorized) {
          await widget.onLogout();
          if (!mounted) return;
          setState(() => _isSubmitting = false);
          return;
        }
        if (!mounted) return;
        setState(() {
          _isSubmitting = false;
          _message = 'Could not log ${added.item.name}: ${error.message}';
          _messageTone = InlineBannerTone.error;
        });
        return;
      }
      _addedItems.remove(added);
      widget.onEntryLogged?.call();
    }

    if (!mounted) return;
    unawaited(HapticFeedback.mediumImpact());
    Navigator.of(context).pop(true);
  }

  String _resultsHeading(String query) {
    if (query.trim().isNotEmpty) return 'Search Results';
    if (_selectedFilter == _filterFavorites) return 'Favorites';
    return 'Recent Foods';
  }

  void _showMealSelector() {
    // Just a simple bottom sheet or dialog to select MealType.
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: MealType.values.map((meal) {
              return ListTile(
                leading: Icon(mealTypeIcon(meal), color: mealTypeAccent(meal)),
                title: Text(meal.label),
                selected: meal == _selectedMeal,
                selectedColor: Theme.of(context).colorScheme.primary,
                onTap: () {
                  _selectMeal(meal);
                  Navigator.of(ctx).pop();
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final query = _searchController.text;
    final results = mergeFoodResults(
      query: query,
      local: _localResults,
      backend: _backendResults,
      off: _offResults,
      fatsecret: _fatsecretResults,
    );
    final hasQuery = query.trim().isNotEmpty;
    final canSubmit = !_isSubmitting && _addedItems.isNotEmpty;

    // Totals scale each item's per-100g values by its chosen amount. The
    // summary tracks the user's focus nutrients, mirroring the today page.
    // Kcal rounds per item then sums, matching each staged row's own label
    // (and the logged entries' display) so the total equals its visible
    // parts (KAN-99).
    var totalKcal = 0;
    final focusTotals = List<double>.filled(_focusSpecs.length, 0);

    for (final entry in _addedItems) {
      final factor = entry.grams / 100.0;
      totalKcal += ((entry.item.kcal100g ?? 0.0) * factor).round();
      for (var i = 0; i < _focusSpecs.length; i++) {
        final per100 = nutrientPer100gForItem(_focusSpecs[i], entry.item);
        focusTotals[i] += (per100 ?? 0.0) * factor;
      }
    }

    final mealLabel = _selectedMeal.label;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        // Solid bar: the old 18-sigma BackdropFilter blurred nothing (content
        // never scrolled under the bar) and burned GPU per frame (KAN-60).
        backgroundColor: scheme.surface,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: scheme.primary),
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Add Meal',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: scheme.onSurface,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.note_add_outlined, color: scheme.primary),
            tooltip: 'Create custom food',
            onPressed: _openCustomFoodPage,
          ),
        ],
      ),
      // Sized so appearing/disappearing (first item staged, last removed)
      // slides in over ~200 ms instead of reflowing the page in one frame.
      bottomNavigationBar: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => SizeTransition(
          sizeFactor: animation,
          axisAlignment: -1,
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: _addedItems.isEmpty
            ? const SizedBox.shrink()
            : _LogBar(
                itemCount: _addedItems.length,
                totalKcal: totalKcal,
                mealLabel: mealLabel,
                isSubmitting: _isSubmitting,
                onSubmit: canSubmit ? _submitItems : null,
              ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
            ),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MealTypeSelectorTile(
                    meal: _selectedMeal,
                    onTap: _showMealSelector,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _SummaryBento(
                    totalKcal: totalKcal,
                    focusSpecs: _focusSpecs,
                    focusTotals: focusTotals,
                  ),
                  if (_addedItems.isNotEmpty)
                    _AddedItemsSection(
                      items: _addedItems,
                      onEdit: _editAddedItem,
                      onInspect: (item) => _openFoodDetail(item),
                      onRemove: _removeAddedItem,
                    ),
                ],
              ),
            ),
          ),
          // Pinned so refining a query after browsing a long result list
          // never means scrolling all the way back up (KAN-60).
          PinnedHeaderSliver(
            child: _SearchHeader(
              controller: _searchController,
              onScan: _isOffRateLimited ? null : _openScanPage,
              isLoading:
                  _isBackendLoading || _isOffLoading || _isFatSecretLoading,
              message: _message,
              messageTone: _messageTone,
              rateLimit: _rateLimit,
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              0,
            ),
            sliver: SliverToBoxAdapter(
              child: _ResultsHeader(
                heading: _resultsHeading(query),
                // The Recent/Favorites toggle only applies to the no-query
                // list.
                toggleLabel: hasQuery
                    ? null
                    : _selectedFilter == _filterFavorites
                    ? 'View Recent'
                    : 'View Favorites',
                onToggleFilter: () => _selectFilter(
                  _selectedFilter == _filterFavorites
                      ? _filterRecent
                      : _filterFavorites,
                ),
              ),
            ),
          ),
          if (results.isEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              sliver: SliverToBoxAdapter(
                child: _EmptyResults(
                  query: query.trim(),
                  onCreateCustomFood: _openCustomFoodPage,
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.xl,
              ),
              // A real sliver grid so result cards build lazily — the old
              // shrinkWrap GridView built every card at once (KAN-60).
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: AppSpacing.md,
                  crossAxisSpacing: AppSpacing.md,
                  childAspectRatio: 1.1,
                ),
                itemCount: results.length,
                itemBuilder: (context, index) {
                  final item = results[index];
                  return _FoodCard(
                    item: item,
                    isAdded: _isAdded(item.item),
                    isEnriching:
                        _enrichingKey != null &&
                        foodResultKey(item.item) == _enrichingKey,
                    onTap: () => _onResultTap(item),
                    onLongPress: () => _onResultLongPress(item),
                  );
                },
              ),
            ),
          // Free-tier attribution requirement (KAN-67): only over the
          // search-results view, and only once a FatSecret row is actually
          // visible — never over the Recent/Favorites default view.
          if (hasQuery && results.any(_isFatSecretResult))
            const SliverToBoxAdapter(child: _FatSecretAttributionFooter()),
        ],
      ),
    );
  }

  static bool _isFatSecretResult(FoodResult result) =>
      result.origin == FoodResultOrigin.fatsecret;
}

/// The "ADDED ITEMS" label plus staged tiles, extracted from build() while
/// restructuring the page into slivers (KAN-60). Tap edits the logged amount;
/// long-press inspects the food itself (KAN-35) — same model as the results
/// grid.
class _AddedItemsSection extends StatelessWidget {
  const _AddedItemsSection({
    required this.items,
    required this.onEdit,
    required this.onInspect,
    required this.onRemove,
  });

  final List<_AddedFood> items;
  final void Function(int index) onEdit;
  final void Function(FoodItem item) onInspect;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.lg),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Text(
            'ADDED ITEMS',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 2.0,
              fontWeight: FontWeight.bold,
              fontSize: 10,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        for (final (index, added) in items.indexed)
          _AddedItemTile(
            added: added,
            onTap: () => onEdit(index),
            onLongPress: () => onInspect(added.item),
            onRemove: () => onRemove(index),
          ),
      ],
    );
  }
}

/// The search strip that pins below the app bar while results scroll under it
/// (KAN-60). Carries the inline banner (errors stay visible next to the field
/// that caused them) plus the rate-limit countdown notice (KAN-96), and
/// always reserves the 2px activity strip so the pinned extent doesn't jump
/// when a live search starts.
class _SearchHeader extends StatelessWidget {
  const _SearchHeader({
    required this.controller,
    required this.onScan,
    required this.isLoading,
    required this.message,
    required this.messageTone,
    required this.rateLimit,
  });

  final TextEditingController controller;
  final VoidCallback? onScan;
  final bool isLoading;
  final String? message;
  final InlineBannerTone? messageTone;

  /// Live pause countdown; the notice listens to it directly so a tick never
  /// rebuilds the page (KAN-124).
  final ValueListenable<_RateLimitCountdown> rateLimit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (message != null) ...[
              InlineBanner(
                message: message!,
                tone: messageTone ?? InlineBannerTone.info,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            GlassSearchBar(controller: controller, onScan: onScan),
            ValueListenableBuilder<_RateLimitCountdown>(
              valueListenable: rateLimit,
              builder: (context, countdown, _) {
                if (!countdown.isActive) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: _RateLimitNotice(
                    // Both budgets share one banner; when both are paused
                    // the longer window is the honest countdown (KAN-96).
                    secondsLeft: max(
                      countdown.offSeconds,
                      countdown.fatsecretSeconds,
                    ),
                    // OFF's pause is the one that greys out the scan button
                    // above, so the copy must say why.
                    scanPaused: countdown.offSeconds > 0,
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.xs),
            SizedBox(
              height: 2,
              child: isLoading
                  ? LinearProgressIndicator(
                      minHeight: 2,
                      color: scheme.primary,
                      backgroundColor: scheme.surfaceContainer,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Seconds left on each online budget's pause (KAN-96); 0 = that budget is
/// free. Immutable so the notifier only fires on real changes.
@immutable
class _RateLimitCountdown {
  const _RateLimitCountdown({this.offSeconds = 0, this.fatsecretSeconds = 0});

  final int offSeconds;
  final int fatsecretSeconds;

  bool get isActive => offSeconds > 0 || fatsecretSeconds > 0;

  _RateLimitCountdown copyWith({int? offSeconds, int? fatsecretSeconds}) =>
      _RateLimitCountdown(
        offSeconds: offSeconds ?? this.offSeconds,
        fatsecretSeconds: fatsecretSeconds ?? this.fatsecretSeconds,
      );

  /// One second later: each running window shrinks, never below zero.
  _RateLimitCountdown tick() => _RateLimitCountdown(
    offSeconds: offSeconds > 0 ? offSeconds - 1 : 0,
    fatsecretSeconds: fatsecretSeconds > 0 ? fatsecretSeconds - 1 : 0,
  );

  @override
  bool operator ==(Object other) =>
      other is _RateLimitCountdown &&
      other.offSeconds == offSeconds &&
      other.fatsecretSeconds == fatsecretSeconds;

  @override
  int get hashCode => Object.hash(offSeconds, fatsecretSeconds);
}

/// Persistent "search paused" notice with a live countdown (KAN-96): while an
/// online budget is exhausted the user sees why results stopped arriving —
/// and, for OFF, why the scan button greyed out — instead of silence. The
/// copy tracks which budget is actually paused: if OFF's window elapses
/// before FatSecret's, scan re-enables and the text drops the scan mention
/// on the same tick.
class _RateLimitNotice extends StatelessWidget {
  const _RateLimitNotice({required this.secondsLeft, required this.scanPaused});

  final int secondsLeft;
  final bool scanPaused;

  @override
  Widget build(BuildContext context) {
    // "Restaurant search" is the FatSecret leg's product framing (KAN-67);
    // backend + packaged-food search keep working during its pause.
    final scope = scanPaused
        ? 'Online search and barcode scan paused'
        : 'Restaurant search paused';
    return InlineBanner(
      message: '$scope — resuming in ${secondsLeft}s',
      icon: Icons.hourglass_top,
    );
  }
}

class _MacroSummaryRow extends StatelessWidget {
  const _MacroSummaryRow({
    required this.label,
    required this.value,
    required this.color,
    required this.progress,
  });

  final String label;
  final String value;
  final Color color;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 0,
                ),
              ),
            ),
            // scaleDown keeps the full amount visible at large text scales;
            // an ellipsized figure would be useless.
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: progress,
          backgroundColor: Theme.of(context).colorScheme.surfaceBright,
          color: color,
          minHeight: 4,
          borderRadius: BorderRadius.circular(999),
        ),
      ],
    );
  }
}

/// The tappable row showing which meal the staged items will be logged to.
class _MealTypeSelectorTile extends StatelessWidget {
  const _MealTypeSelectorTile({required this.meal, required this.onTap});

  final MealType meal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  // The selected meal's own icon + accent (KAN-3) so the
                  // destination reads at a glance, matching the today page.
                  Icon(mealTypeIcon(meal), color: mealTypeAccent(meal)),
                  const SizedBox(width: AppSpacing.md),
                  Flexible(
                    child: Text(
                      meal.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.expand_more, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// The bento summary pair: total energy of the staged items next to their
/// focus-nutrient totals (same nutrients the today page tracks).
class _SummaryBento extends StatelessWidget {
  const _SummaryBento({
    required this.totalKcal,
    required this.focusSpecs,
    required this.focusTotals,
  });

  final int totalKcal;
  final List<NutrientSpec> focusSpecs;
  final List<double> focusTotals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // A min-height instead of a fixed height so large system text scales
    // grow the cards rather than clipping them; IntrinsicHeight keeps the
    // two cards equal (KAN-40).
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 140),
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'TOTAL ENERGY',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 2.0,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  // The hero figure shrinks to fit rather than overflowing the
                  // half-width card at large system text scales (KAN-40).
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          totalKcal.toString(),
                          style: theme.textTheme.displayMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: scheme.primary,
                            height: 1,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'kcal',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              constraints: const BoxConstraints(minHeight: 140),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (var i = 0; i < focusSpecs.length; i++)
                    _MacroSummaryRow(
                      label: focusSpecs[i].label,
                      value: _focusValueText(
                        focusTotals[i],
                        focusSpecs[i].unit,
                      ),
                      color:
                          LuminaHealthColors.focusAccents[i %
                              LuminaHealthColors.focusAccents.length],
                      progress:
                          (focusTotals[i] /
                                  (focusSpecs[i].dailyTarget *
                                      _mealShareOfDailyTarget))
                              .clamp(0.0, 1.0),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One staged item in the Added list: thumb plus amount + kcal line. Tap
/// edits, swipe (endToStart) removes with Undo (KAN-39) — no persistent
/// remove button, and the editor's "Remove from meal" is the visible path.
class _AddedItemTile extends StatelessWidget {
  const _AddedItemTile({
    required this.added,
    required this.onTap,
    required this.onLongPress,
    required this.onRemove,
  });

  final _AddedFood added;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final grams = added.grams;
    final kcal = ((added.item.kcal100g ?? 0) * grams / 100).round();
    final amountLabel = describeAmount(grams, added.item);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Dismissible(
        key: ObjectKey(added),
        // endToStart only, so the swipe never fights the Android back
        // gesture on the left edge.
        direction: DismissDirection.endToStart,
        background: SwipeDeleteBackground(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        onDismissed: (_) => onRemove(),
        // The swipe gesture is invisible to screen readers; expose the
        // removal as an explicit accessibility action instead.
        child: Semantics(
          customSemanticsActions: {
            CustomSemanticsAction(label: 'Remove ${added.item.name}'): onRemove,
          },
          child: Material(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              onTap: onTap,
              onLongPress: onLongPress,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    FoodThumb(
                      url: added.item.imageUrl?.trim().isNotEmpty == true
                          ? added.item.imageUrl!.trim()
                          : null,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            added.item.name,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '$amountLabel • $kcal kcal',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The results-section heading plus the Recent/Favorites toggle (shown only
/// when browsing without a query — pass a null [toggleLabel] to hide it).
class _ResultsHeader extends StatelessWidget {
  const _ResultsHeader({
    required this.heading,
    required this.toggleLabel,
    required this.onToggleFilter,
  });

  final String heading;
  final String? toggleLabel;
  final VoidCallback onToggleFilter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              heading.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 2.0,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (toggleLabel != null)
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
              ),
              onPressed: onToggleFilter,
              child: Text(
                toggleLabel!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Empty results state: nudges toward search/scan when browsing, or toward a
/// respelling/scan/custom food when a query found nothing.
class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.query, required this.onCreateCustomFood});

  final String query;
  final VoidCallback onCreateCustomFood;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasQuery = query.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
      child: Center(
        child: Column(
          children: [
            Icon(
              hasQuery ? Icons.search_off : Icons.restaurant_menu,
              size: 40,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              hasQuery
                  ? 'No foods found for "$query"'
                  : 'Search for a food or scan a barcode',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (hasQuery) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Try a different spelling or scan the package.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: onCreateCustomFood,
              icon: const Icon(Icons.add),
              label: const Text('Create custom food'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact amount + unit for the summary rows ("32g", "120 mg").
String _focusValueText(double value, String unit) =>
    '${formatNutrientValue(value)}${unit == 'g' ? 'g' : ' $unit'}';

// Fraction of a nutrient's daily target treated as "one meal's worth", giving
// the summary bars a meaningful scale. Uses each focus nutrient's (possibly
// personalized) daily target, so the bars track the user's own goals.
const double _mealShareOfDailyTarget = 0.3;

/// A food the user has chosen to log, paired with the amount (grams) to log.
class _AddedFood {
  const _AddedFood({required this.item, required this.grams});

  final FoodItem item;
  final double grams;
}

class _FoodCard extends StatelessWidget {
  const _FoodCard({
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.isAdded = false,
    this.isEnriching = false,
  });

  final FoodResult item;
  final VoidCallback onTap;

  /// Long-press action — opens the read-first food detail page (KAN-35).
  final VoidCallback? onLongPress;
  final bool isAdded;
  final bool isEnriching;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(AppRadius.lg * 1.5);

    final imageUrl = item.item.imageUrl?.trim().isNotEmpty == true
        ? item.item.imageUrl!.trim()
        : null;

    return Semantics(
      button: true,
      label: isAdded
          ? '${item.item.name}, added. Edit amount'
          : 'Add ${item.item.name}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: isEnriching ? null : onTap,
          onLongPress: isEnriching ? null : onLongPress,
          child: Ink(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: radius,
              border: Border.all(
                color: isAdded ? scheme.primary : Colors.transparent,
                width: isAdded ? 2 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Image / placeholder / retry layer.
                  FoodImage(url: imageUrl),
                  // Bottom gradient keeps the white name text legible over both
                  // real photos and the placeholder.
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.8),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (isEnriching)
                    Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.35),
                        child: Center(
                          child: SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: scheme.onPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (isAdded)
                    Positioned(
                      top: AppSpacing.sm,
                      right: AppSpacing.sm,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check,
                          size: 14,
                          color: scheme.onPrimary,
                        ),
                      ),
                    ),
                  // The user's own foods are marked so it's clear these
                  // values are theirs, not the shared catalog's.
                  if (item.item.isCustom)
                    Positioned(
                      top: AppSpacing.sm,
                      left: AppSpacing.sm,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          item.item.isOverride ? 'Edited by you' : 'Yours',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSecondaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: AppSpacing.sm,
                    right: AppSpacing.sm,
                    bottom: AppSpacing.sm,
                    child: Text(
                      item.item.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Free-tier attribution FatSecret's platform terms require (KAN-67).
/// Extracted per the size-discipline rule; muted labelSmall/onSurfaceVariant
/// styling so it reads as a footnote, not another result.
class _FatSecretAttributionFooter extends StatelessWidget {
  const _FatSecretAttributionFooter();

  Future<void> _open() {
    return url_launcher.launchUrl(
      Uri.parse(kFatSecretAttributionUrl),
      mode: url_launcher.LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _open,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              child: Text(
                'Powered by FatSecret',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Persistent bottom action bar — the single primary CTA for committing the
/// meal. Surfaces the live item count + total calories so the user knows
/// exactly what they are logging, and shows an inline spinner while submitting.
class _LogBar extends StatelessWidget {
  const _LogBar({
    required this.itemCount,
    required this.totalKcal,
    required this.mealLabel,
    required this.isSubmitting,
    required this.onSubmit,
  });

  final int itemCount;
  final int totalKcal;
  final String mealLabel;
  final bool isSubmitting;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final itemLabel = itemCount == 1 ? '1 item' : '$itemCount items';

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      itemLabel,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '$totalKcal kcal total',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Flexible(
                child: FilledButton(
                  onPressed: isSubmitting ? null : onSubmit,
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                    disabledBackgroundColor: scheme.primary.withValues(
                      alpha: 0.5,
                    ),
                    minimumSize: const Size(0, 52),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  child: isSubmitting
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: scheme.onPrimary,
                          ),
                        )
                      : Text(
                          'Log to $mealLabel',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: scheme.onPrimary,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
