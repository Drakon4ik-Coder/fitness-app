import 'dart:async';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../ui_components/ui_components.dart';
import '../../ui_system/tokens.dart';
import 'data/api_exceptions.dart';
import 'data/food_local_db.dart';
import 'data/food_models.dart';
import 'data/foods_api_service.dart';
import 'data/nutrition_api_service.dart';
import 'data/off_client.dart';
import 'data/off_image_downloader.dart';
import 'data/off_mapper.dart';
import 'data/off_rate_limiter.dart';
import 'live_search_controller.dart';
import 'nutrition_scan_page.dart';

const String _filterRecent = 'Recent';
const String _filterFavorites = 'Favorites';

List<String> categoryTagsForQuery(String queryLower) {
  final trimmed = queryLower.trim();
  if (trimmed.isEmpty || trimmed.contains(' ')) {
    return const [];
  }
  final normalized = trimmed
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (normalized.isEmpty) {
    return const [];
  }
  final tags = <String>{'en:$normalized'};
  if (!normalized.endsWith('s')) {
    tags.add('en:${normalized}s');
  }
  return tags.toList();
}

class AddFoodPage extends StatefulWidget {
  const AddFoodPage({
    super.key,
    required this.localDb,
    required this.foodsApi,
    required this.nutritionApi,
    required this.offClient,
    required this.onLogout,
    required this.selectedDate,
  });

  final FoodLocalDb localDb;
  final FoodsApiService foodsApi;
  final NutritionApiService nutritionApi;
  final OffClient offClient;
  final Future<void> Function() onLogout;
  final DateTime selectedDate;

  @override
  State<AddFoodPage> createState() => _AddFoodPageState();
}

class _AddFoodPageState extends State<AddFoodPage> {
  final TextEditingController _searchController = TextEditingController();
  final OffMapper _offMapper = OffMapper();
  final OffImageDownloader _imageDownloader = OffImageDownloader();
  late final LiveSearchController _liveSearch;
  Timer? _offBlockTimer;

  static const Duration _scanCooldown = Duration(seconds: 3);
  DateTime? _offBlockedUntil;
  String? _lastScannedBarcode;
  DateTime? _lastScannedAt;

  MealType _selectedMeal = MealType.breakfast;
  String _selectedFilter = _filterRecent;

  // Track actual items (with their per-item amount) instead of search indices
  final List<_AddedFood> _addedItems = [];

  bool _isBackendLoading = false;
  bool _isOffLoading = false;
  bool _isSubmitting = false;
  bool _ignoreSearchChange = false;

  String? _message;
  InlineBannerTone? _messageTone;

  List<FoodItem> _localResults = [];
  List<FoodItem> _backendResults = [];
  List<FoodItem> _offResults = [];

  @override
  void initState() {
    super.initState();
    // The controller owns the shared 300ms debounce + per-query CancelToken +
    // 2-char floor (D-06/D-07/D-08). The page hands it `setState`-driven setters
    // so debounced backend/OFF results flow back into the existing merge fields.
    _liveSearch = LiveSearchController(
      offClient: widget.offClient,
      foodsApi: widget.foodsApi,
      offMapper: _offMapper,
      onBackendResults: (results) {
        if (!mounted) return;
        setState(() => _backendResults = results);
      },
      onOffResults: (results) {
        if (!mounted) return;
        setState(() => _offResults = results);
      },
      onLoadingChanged: ({required bool backend, required bool off}) {
        if (!mounted) return;
        setState(() {
          _isBackendLoading = backend;
          _isOffLoading = off;
        });
      },
      onUnauthorized: widget.onLogout,
    );
    _searchController.addListener(_handleSearchChange);
    _loadFilterResults();
  }

  @override
  void dispose() {
    _liveSearch.dispose();
    _offBlockTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  bool get _isOffRateLimited {
    final until = _offBlockedUntil;
    if (until == null) return false;
    return until.isAfter(DateTime.now());
  }

  void _applyOffLimit(OffRateLimitException error) {
    final until = DateTime.now().add(error.retryAfter);
    _offBlockedUntil = until;
    _offBlockTimer?.cancel();
    if (error.retryAfter > Duration.zero) {
      _offBlockTimer = Timer(error.retryAfter, () {
        if (!mounted) return;
        setState(() {
          _offBlockedUntil = null;
        });
      });
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
        _message = null;
        _messageTone = null;
        _isBackendLoading = false;
        _isOffLoading = false;
      });
      _loadFilterResults();
      return;
    }

    setState(() {
      _offResults = [];
      _backendResults = [];
      _message = null;
      _messageTone = null;
    });
    // Local cache stays instant + un-debounced (D-06); the controller owns the
    // shared 300ms debounce that fires backend typeahead + OFF together.
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
    final key = _resultKey(item);
    if (key == null) return -1;
    for (var i = 0; i < _addedItems.length; i++) {
      if (_resultKey(_addedItems[i].item) == key) return i;
    }
    return -1;
  }

  bool _isAdded(FoodItem item) => _indexOfAdded(item) >= 0;

  double _defaultGramsFor(FoodItem item) {
    final serving = item.servingSizeG;
    return (serving != null && serving > 0) ? serving : 100.0;
  }

  // One-tap quick add: tapping a result immediately logs it with a smart
  // default (1 serving when known, else 100 g) and offers Undo. The amount can
  // be fine-tuned later by tapping the item in the Added list. If the food is
  // already added we open its editor instead, so it can never be added twice.
  Future<void> _onResultTap(FoodItem item) async {
    FocusScope.of(context).unfocus();
    final existingIndex = _indexOfAdded(item);
    if (existingIndex >= 0) {
      await _editAddedItem(existingIndex);
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _addedItems.add(_AddedFood(item: item, grams: _defaultGramsFor(item)));
    });
  }

  Future<void> _editAddedItem(int index) async {
    final entry = _addedItems[index];
    final result = await _showAmountSheet(
      item: entry.item,
      initialGrams: entry.grams,
      isEditing: true,
    );
    if (result == null || !mounted) return;
    setState(() {
      if (result.removed) {
        _addedItems.removeAt(index);
      } else if (result.grams != null) {
        _addedItems[index] = _AddedFood(item: entry.item, grams: result.grams!);
      }
    });
  }

  Future<_AmountResult?> _showAmountSheet({
    required FoodItem item,
    required double initialGrams,
    required bool isEditing,
  }) {
    return showModalBottomSheet<_AmountResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AmountSheet(
        item: item,
        initialGrams: initialGrams,
        isEditing: isEditing,
      ),
    );
  }

  Future<void> _openScanPage() async {
    FocusScope.of(context).unfocus();
    final barcode = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const NutritionScanPage()),
    );
    if (barcode == null || barcode.trim().isEmpty) return;
    await _handleBarcodeScan(barcode.trim());
  }

  Future<void> _handleBarcodeScan(String barcode) async {
    if (_isOffRateLimited) {
      setState(() {
        _message = 'OpenFoodFacts is temporarily rate limited. Try again soon.';
        _messageTone = InlineBannerTone.info;
      });
      return;
    }
    final now = DateTime.now();
    if (_lastScannedBarcode == barcode &&
        _lastScannedAt != null &&
        now.difference(_lastScannedAt!) < _scanCooldown) {
      return;
    }
    _lastScannedBarcode = barcode;
    _lastScannedAt = now;
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
      _ignoreSearchChange = true;
      _searchController.text = barcode;
      _searchController.selection = TextSelection.collapsed(
        offset: _searchController.text.length,
      );
      _ignoreSearchChange = false;
      setState(() {
        _offResults = [item];
        _backendResults = [];
        _localResults = [];
        _isOffLoading = false;
        // Auto add scanned item? Maybe not, let user tap it.
      });
    } on OffRateLimitException catch (error) {
      if (!mounted) return;
      _applyOffLimit(error);
      setState(() {
        _isOffLoading = false;
        _message = error.message;
        _messageTone = InlineBannerTone.info;
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
    final result = await _imageDownloader.downloadImage(imageUrl);
    if (result == null) return null;
    return widget.foodsApi.uploadFoodImages(
      foodItemId: backendId,
      bytes: result.bytes,
      contentType: result.contentType,
      imageSignature: item.imageSignature,
    );
  }

  Future<void> _submitItems() async {
    if (_addedItems.isEmpty) return;

    setState(() {
      _isSubmitting = true;
      _message = null;
      _messageTone = null;
    });

    try {
      final now = DateTime.now();
      final consumedAt = DateTime(
        widget.selectedDate.year,
        widget.selectedDate.month,
        widget.selectedDate.day,
        now.hour,
        now.minute,
      );

      for (final added in _addedItems) {
        FoodItem selected = added.item;
        bool imagesOk = false;
        if (selected.backendId == null) {
          if (selected.contentHash.isNotEmpty) {
            final check = await widget.foodsApi.checkFood(
              source: selected.source,
              externalId: selected.externalId,
              contentHash: selected.contentHash,
              imageSignature: selected.imageSignature,
            );
            if (check.upToDate && check.foodItemId != null) {
              selected = selected.copyWith(backendId: check.foodItemId);
              imagesOk = check.imagesOk;
            } else {
              final result = await widget.foodsApi.ingestFood(selected);
              selected = result.item;
              imagesOk = result.imagesOk;
            }
          } else {
            final result = await widget.foodsApi.ingestFood(selected);
            selected = result.item;
            imagesOk = result.imagesOk;
          }
        }
        if (selected.backendId == null) {
          throw ApiException('Unable to resolve food item id.');
        }

        if (!imagesOk) {
          final uploaded = await _tryUploadImages(selected);
          if (uploaded != null) selected = uploaded;
        }

        final stored = await widget.localDb.upsertFood(selected);
        selected = stored;

        await widget.nutritionApi.createEntry(
          foodItemId: selected.backendId!,
          mealType: _selectedMeal.name,
          quantityG: added.grams,
          consumedAt: consumedAt,
        );

        if (selected.localId != null) {
          await widget.localDb.updateLastUsed(selected.localId!, consumedAt);
        }
      }

      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(true);
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
        _message = error.message;
        _messageTone = InlineBannerTone.error;
      });
    }
  }

  String _resultsHeading(String query) {
    if (query.trim().isNotEmpty) return 'Search Results';
    if (_selectedFilter == _filterFavorites) return 'Favorites';
    return 'Recent Foods';
  }

  List<_FoodResult> _buildResults(String query) {
    final trimmed = query.trim();
    final results = <_FoodResult>[];
    final seenKeys = <String>{};

    void addItems(List<FoodItem> items, _FoodResultOrigin origin) {
      for (final item in items) {
        final key = _resultKey(item);
        if (key == null || seenKeys.contains(key)) continue;
        seenKeys.add(key);
        results.add(_FoodResult(item: item, origin: origin));
      }
    }

    if (trimmed.isEmpty) {
      addItems(_localResults, _FoodResultOrigin.local);
      return results;
    }

    addItems(_localResults, _FoodResultOrigin.local);
    addItems(_backendResults, _FoodResultOrigin.backend);
    addItems(_offResults, _FoodResultOrigin.off);
    final queryLower = trimmed.toLowerCase();
    results.sort((a, b) {
      final scoreA = _resultScore(a, queryLower);
      final scoreB = _resultScore(b, queryLower);
      if (scoreA != scoreB) return scoreB.compareTo(scoreA);
      final lengthCompare = a.item.name.length.compareTo(b.item.name.length);
      if (lengthCompare != 0) return lengthCompare;
      return a.item.name.compareTo(b.item.name);
    });
    return results;
  }

  String? _resultKey(FoodItem item) {
    if (item.barcode != null && item.barcode!.isNotEmpty) {
      return 'barcode:${item.barcode}';
    }
    if (item.backendId != null) return 'backend:${item.backendId}';
    if (item.externalId.isNotEmpty) return 'external:${item.externalId}';
    return null;
  }

  int _nameMatchScore(String name, String queryLower) {
    if (queryLower.isEmpty) return 0;
    final nameLower = name.toLowerCase();
    int score = 0;
    if (nameLower == queryLower) score += 400;
    if (nameLower.startsWith(queryLower)) score += 300;
    final wordMatch = RegExp(
      r'\b' + RegExp.escape(queryLower),
    ).hasMatch(nameLower);
    if (wordMatch) {
      score += 200;
    } else if (nameLower.contains(queryLower)) {
      score += 100;
    }
    score -= nameLower.length;
    return score;
  }

  int _resultScore(_FoodResult result, String queryLower) {
    int score = _nameMatchScore(result.item.name, queryLower);
    switch (result.origin) {
      case _FoodResultOrigin.off:
        score += 5;
        break;
      case _FoodResultOrigin.backend:
        score += 3;
        break;
      case _FoodResultOrigin.local:
        score += 1;
        break;
    }
    return score;
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
              final label = meal.name[0].toUpperCase() + meal.name.substring(1);
              return ListTile(
                title: Text(label),
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
    final results = _buildResults(query);
    final hasQuery = query.trim().isNotEmpty;
    final canSubmit = !_isSubmitting && _addedItems.isNotEmpty;

    // Totals scale each item's per-100g macros by its chosen amount.
    double totalEnergy = 0;
    double totalProtein = 0;
    double totalCarbs = 0;
    double totalFats = 0;

    for (final entry in _addedItems) {
      final factor = entry.grams / 100.0;
      totalEnergy += (entry.item.kcal100g ?? 0.0) * factor;
      totalProtein += (entry.item.proteinG100g ?? 0.0) * factor;
      totalCarbs += (entry.item.carbsG100g ?? 0.0) * factor;
      totalFats += (entry.item.fatG100g ?? 0.0) * factor;
    }

    final mealLabel =
        _selectedMeal.name[0].toUpperCase() + _selectedMeal.name.substring(1);

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface.withValues(alpha: 0.7),
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: const SizedBox.expand(),
          ),
        ),
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
      ),
      bottomNavigationBar: _addedItems.isEmpty
          ? null
          : _LogBar(
              itemCount: _addedItems.length,
              totalKcal: totalEnergy.round(),
              mealLabel: mealLabel,
              isSubmitting: _isSubmitting,
              onSubmit: canSubmit ? _submitItems : null,
            ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Meal Type Selector
            InkWell(
              onTap: _showMealSelector,
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
                    Row(
                      children: [
                        Icon(Icons.restaurant, color: scheme.secondary),
                        const SizedBox(width: AppSpacing.md),
                        Text(
                          mealLabel,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Icon(Icons.expand_more, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Summary Bar (Bento Style)
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 140,
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
                            fontSize: 10,
                          ),
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              totalEnergy.round().toString(),
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
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    height: 140,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _MacroSummaryRow(
                          label: 'Protein',
                          value: '${totalProtein.round()}g',
                          color: scheme.secondary,
                          progress: (totalProtein / _proteinRefG).clamp(
                            0.0,
                            1.0,
                          ),
                        ),
                        _MacroSummaryRow(
                          label: 'Carbs',
                          value: '${totalCarbs.round()}g',
                          color: scheme.tertiary,
                          progress: (totalCarbs / _carbsRefG).clamp(0.0, 1.0),
                        ),
                        _MacroSummaryRow(
                          label: 'Fats',
                          value: '${totalFats.round()}g',
                          color: scheme.primary,
                          progress: (totalFats / _fatsRefG).clamp(0.0, 1.0),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            // Added Items List
            if (_addedItems.isNotEmpty) ...[
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
              ..._addedItems.asMap().entries.map((entry) {
                final index = entry.key;
                final added = entry.value;
                final grams = added.grams;
                final kcal = ((added.item.kcal100g ?? 0) * grams / 100).round();
                final amountLabel = _amountLabel(
                  grams,
                  added.item.servingSizeG,
                );
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: Material(
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.4,
                    ),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      onTap: () => _editAddedItem(index),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
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
                            Icon(
                              Icons.edit_outlined,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            IconButton(
                              icon: Icon(
                                Icons.remove_circle,
                                color: scheme.error,
                              ),
                              tooltip: 'Remove ${added.item.name}',
                              onPressed: () =>
                                  setState(() => _addedItems.removeAt(index)),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],

            const SizedBox(height: AppSpacing.lg),

            // Search Bar
            if (_message != null) ...[
              InlineBanner(
                message: _message!,
                tone: _messageTone ?? InlineBannerTone.info,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            GlassSearchBar(
              controller: _searchController,
              onScan: _isOffRateLimited ? null : _openScanPage,
            ),
            if (_isBackendLoading || _isOffLoading) ...[
              const SizedBox(height: AppSpacing.sm),
              LinearProgressIndicator(
                minHeight: 2,
                color: scheme.primary,
                backgroundColor: scheme.surfaceContainer,
              ),
            ],

            const SizedBox(height: AppSpacing.lg),

            // Food Grid (Quick Add / Search Results)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _resultsHeading(query).toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 2.0,
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                  if (!hasQuery)
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                      ),
                      onPressed: () {
                        _selectFilter(
                          _selectedFilter == _filterFavorites
                              ? _filterRecent
                              : _filterFavorites,
                        );
                      },
                      child: Text(
                        _selectedFilter == _filterFavorites
                            ? 'View Recent'
                            : 'View Favorites',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),

            if (results.isEmpty)
              Padding(
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
                            ? 'No foods found for "${query.trim()}"'
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
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.7,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              )
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
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
                    onTap: () => _onResultTap(item.item),
                  );
                },
              ),

            const SizedBox(height: AppSpacing.xl),
          ],
        ),
      ),
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
            Text(
              label.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                letterSpacing: 0,
              ),
            ),
            Text(
              value,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
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

// Per-meal reference macro amounts used to fill the summary bars. These give
// the progress bars a meaningful scale (roughly one meal's worth) until
// per-user targets are wired up.
const double _proteinRefG = 40;
const double _carbsRefG = 80;
const double _fatsRefG = 30;

enum MealType { breakfast, lunch, dinner, snacks }

enum _FoodResultOrigin { local, backend, off }

class _FoodResult {
  const _FoodResult({required this.item, required this.origin});

  final FoodItem item;
  final _FoodResultOrigin origin;
}

/// A food the user has chosen to log, paired with the amount (grams) to log.
class _AddedFood {
  const _AddedFood({required this.item, required this.grams});

  final FoodItem item;
  final double grams;
}

/// Formats a number without a trailing `.0` and at most one decimal place.
String _formatAmount(double value) {
  return value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1);
}

/// Human label for a logged amount. When the food has a known serving size the
/// amount reads in servings with grams in parentheses ("1 serving (215 g)"),
/// otherwise it falls back to plain grams ("150 g").
String _amountLabel(double grams, double? servingSizeG) {
  if (servingSizeG != null && servingSizeG > 0) {
    final servings = grams / servingSizeG;
    final unit = (servings - 1).abs() < 0.001 ? 'serving' : 'servings';
    return '${_formatAmount(servings)} $unit (${_formatAmount(grams)} g)';
  }
  return '${_formatAmount(grams)} g';
}

/// Outcome of the amount bottom sheet: either a saved [grams] amount or a
/// request to [removed] the item from the meal.
class _AmountResult {
  const _AmountResult._({this.grams, this.removed = false});

  factory _AmountResult.save(double grams) => _AmountResult._(grams: grams);
  factory _AmountResult.remove() => const _AmountResult._(removed: true);

  final double? grams;
  final bool removed;
}

class _FoodCard extends StatelessWidget {
  const _FoodCard({
    required this.item,
    required this.onTap,
    this.isAdded = false,
  });

  final _FoodResult item;
  final VoidCallback onTap;
  final bool isAdded;

  IconData _originIcon(_FoodResultOrigin origin) {
    switch (origin) {
      case _FoodResultOrigin.local:
        return Icons.history;
      case _FoodResultOrigin.backend:
        return Icons.cloud;
      case _FoodResultOrigin.off:
        return Icons.public;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(AppRadius.lg * 1.5);

    final kcal = item.item.kcal100g?.round();
    final kcalLabel = kcal == null ? 'kcal n/a' : '$kcal kcal / 100g';
    final imageUrl = item.item.imageUrl?.trim().isNotEmpty == true
        ? item.item.imageUrl!.trim()
        : null;
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;

    return Semantics(
      button: true,
      label: isAdded
          ? '${item.item.name}, added. Edit amount'
          : 'Add ${item.item.name}, $kcalLabel',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
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
                  if (hasImage) ...[
                    Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.shrink(),
                    ),
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
                  ] else
                    Container(
                      color: scheme.surfaceContainerHigh,
                      child: Center(
                        child: Icon(
                          _originIcon(item.origin),
                          color: scheme.onSurfaceVariant,
                          size: 32,
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
                  Positioned(
                    left: AppSpacing.sm,
                    right: AppSpacing.sm,
                    bottom: AppSpacing.sm,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.item.name,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          kcalLabel.toUpperCase(),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontSize: 10,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
    );
  }
}

enum _AmountUnit { servings, grams }

/// Bottom sheet for choosing how much of a food to log. Re-used for both adding
/// a new item and editing the amount of an already-added one.
///
/// Designed to be keyboard-free for the common case: a +/- stepper and quick
/// presets cover most edits with zero typing (so the sheet no longer fights the
/// keyboard animation on open). For foods with a known serving size a
/// Servings/Grams toggle lets the user think in pieces/servings instead of raw
/// grams. The number stays tappable for a precise custom value.
class _AmountSheet extends StatefulWidget {
  const _AmountSheet({
    required this.item,
    required this.initialGrams,
    required this.isEditing,
  });

  final FoodItem item;
  final double initialGrams;
  final bool isEditing;

  @override
  State<_AmountSheet> createState() => _AmountSheetState();
}

class _AmountSheetState extends State<_AmountSheet> {
  late final TextEditingController _controller;
  late _AmountUnit _unit;

  double? get _serving {
    final serving = widget.item.servingSizeG;
    return (serving != null && serving > 0) ? serving : null;
  }

  bool get _hasServing => _serving != null;

  @override
  void initState() {
    super.initState();
    _unit = _hasServing ? _AmountUnit.servings : _AmountUnit.grams;
    _controller = TextEditingController(
      text: _formatAmount(_valueForGrams(widget.initialGrams)),
    );
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _valueForGrams(double grams) {
    return _unit == _AmountUnit.servings ? grams / _serving! : grams;
  }

  double? get _value {
    final value = double.tryParse(_controller.text.trim().replaceAll(',', '.'));
    if (value == null || value <= 0) return null;
    return value;
  }

  double? get _grams {
    final value = _value;
    if (value == null) return null;
    return _unit == _AmountUnit.servings ? value * _serving! : value;
  }

  double get _step => _unit == _AmountUnit.servings ? 1.0 : 10.0;

  List<double> get _presets => _unit == _AmountUnit.servings
      ? const [1, 2, 3]
      : const [50, 100, 150, 200];

  void _setText(double value) {
    _controller.text = _formatAmount(value);
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
  }

  void _bump(int direction) {
    final current = _value ?? 0;
    var next = current + direction * _step;
    if (next < _step) next = _step;
    _setText(next);
  }

  void _setUnit(_AmountUnit unit) {
    if (unit == _unit || !_hasServing) return;
    final grams = _grams ?? widget.initialGrams;
    setState(() {
      _unit = unit;
      _setText(unit == _AmountUnit.servings ? grams / _serving! : grams);
    });
  }

  void _submit() {
    final grams = _grams;
    if (grams == null) return;
    Navigator.of(context).pop(_AmountResult.save(grams));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final grams = _grams;
    final factor = (grams ?? 0) / 100.0;

    final kcal = ((widget.item.kcal100g ?? 0) * factor).round();
    final protein = (widget.item.proteinG100g ?? 0) * factor;
    final carbs = (widget.item.carbsG100g ?? 0) * factor;
    final fats = (widget.item.fatG100g ?? 0) * factor;

    final unitLabel = _unit == _AmountUnit.grams
        ? 'grams'
        : ((_value ?? 0) == 1 ? 'serving' : 'servings');
    final conversion = _conversionLabel(grams);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg * 1.5),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: AppSpacing.md),
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Text(
              widget.item.name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              widget.item.kcal100g == null
                  ? 'Calories per 100g unavailable'
                  : '${widget.item.kcal100g!.round()} kcal per 100g',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Unit toggle (only when the food has a known serving size)
            if (_hasServing) ...[
              SegmentedButton<_AmountUnit>(
                segments: const [
                  ButtonSegment(
                    value: _AmountUnit.servings,
                    label: Text('Servings'),
                  ),
                  ButtonSegment(value: _AmountUnit.grams, label: Text('Grams')),
                ],
                selected: {_unit},
                onSelectionChanged: (s) => _setUnit(s.first),
                showSelectedIcon: false,
                style: ButtonStyle(visualDensity: VisualDensity.compact),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],

            // Stepper: −  [ number ]  +
            Row(
              children: [
                IconButton.filledTonal(
                  onPressed: () => _bump(-1),
                  iconSize: 24,
                  tooltip: 'Decrease',
                  icon: const Icon(Icons.remove),
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textAlign: TextAlign.center,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: () => _bump(1),
                  iconSize: 24,
                  tooltip: 'Increase',
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            Center(
              child: Text(
                conversion == null ? unitLabel : '$unitLabel  •  $conversion',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Quick presets
            Wrap(
              alignment: WrapAlignment.center,
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: _presets.map((preset) {
                final selected = (_value ?? -1) == preset;
                final label = _unit == _AmountUnit.servings
                    ? '${_formatAmount(preset)}×'
                    : '${_formatAmount(preset)}g';
                return ChoiceChip(
                  label: Text(label),
                  selected: selected,
                  showCheckmark: false,
                  onSelected: (_) => _setText(preset),
                  backgroundColor: scheme.surfaceContainerLow,
                  selectedColor: scheme.primary,
                  labelStyle: theme.textTheme.labelLarge?.copyWith(
                    color: selected ? scheme.onPrimary : scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  side: BorderSide.none,
                );
              }).toList(),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Live preview
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '$kcal',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: scheme.primary,
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
                  Row(
                    children: [
                      _MacroPill(
                        label: 'P',
                        value: protein,
                        color: scheme.secondary,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      _MacroPill(
                        label: 'C',
                        value: carbs,
                        color: scheme.tertiary,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      _MacroPill(
                        label: 'F',
                        value: fats,
                        color: scheme.primary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Primary action
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: grams == null ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                child: Text(
                  widget.isEditing ? 'Save changes' : 'Add to meal',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: scheme.onPrimary,
                  ),
                ),
              ),
            ),
            if (widget.isEditing) ...[
              const SizedBox(height: AppSpacing.xs),
              TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(_AmountResult.remove()),
                child: Text(
                  'Remove from meal',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.error,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String? _conversionLabel(double? grams) {
    if (grams == null) return null;
    if (_unit == _AmountUnit.servings) {
      return '${_formatAmount(grams)} g';
    }
    if (_hasServing) {
      final servings = grams / _serving!;
      final unit = (servings - 1).abs() < 0.001 ? 'serving' : 'servings';
      return '≈ ${_formatAmount(servings)} $unit';
    }
    return null;
  }
}

class _MacroPill extends StatelessWidget {
  const _MacroPill({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          '${value.round()}g',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
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
