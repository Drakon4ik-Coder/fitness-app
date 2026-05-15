import 'dart:async';
import 'package:flutter/material.dart';

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
  Timer? _debounce;
  Timer? _offBlockTimer;

  static const Duration _scanCooldown = Duration(seconds: 3);
  DateTime? _offBlockedUntil;
  String? _lastScannedBarcode;
  DateTime? _lastScannedAt;

  MealType _selectedMeal = MealType.breakfast;
  String _selectedFilter = _filterRecent;
  
  // Track actual items instead of search result indices 
  final List<FoodItem> _addedItems = [];

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
    _searchController.addListener(_handleSearchChange);
    _loadFilterResults();
  }

  @override
  void dispose() {
    _debounce?.cancel();
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
      _debounce?.cancel();
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
    _loadLocalSearch(query);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _loadBackendSearch(query);
    });
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

  Future<void> _loadBackendSearch(String query) async {
    if (!mounted) return;
    setState(() {
      _isBackendLoading = true;
      _message = null;
      _messageTone = null;
    });
    try {
      final results = await widget.foodsApi.typeahead(query);
      if (!mounted) return;
      if (_searchController.text.trim() != query) {
        setState(() => _isBackendLoading = false);
        return;
      }
      setState(() {
        _backendResults = results;
        _isBackendLoading = false;
      });
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await widget.onLogout();
        if (!mounted) return;
        setState(() => _isBackendLoading = false);
        return;
      }
      if (!mounted) return;
      setState(() {
        _isBackendLoading = false;
        _message = error.message;
        _messageTone = InlineBannerTone.error;
      });
    }
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

  void _appendResult(FoodItem item) {
    setState(() {
      _addedItems.add(item);
    });
  }
  
  void _removeItem(int index) {
    setState(() {
      _addedItems.removeAt(index);
    });
  }

  Future<void> _openScanPage() async {
    FocusScope.of(context).unfocus();
    final barcode = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const NutritionScanPage(),
      ),
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

  Future<void> _searchOnline() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    if (_isOffRateLimited) {
      setState(() {
        _message = 'OpenFoodFacts is temporarily rate limited. Try again soon.';
        _messageTone = InlineBannerTone.info;
      });
      return;
    }
    final queryLower = query.toLowerCase();
    setState(() {
      _isOffLoading = true;
      _message = null;
      _messageTone = null;
    });
    try {
      final locale = Localizations.localeOf(context).languageCode;
      final baseResults = await widget.offClient.searchProducts(query);
      List<OffProductResponse> effectiveResults = baseResults;
      final bool hasCategoryMatch = _hasCategoryMatch(baseResults, queryLower);
      if (baseResults.isEmpty || !hasCategoryMatch) {
        final categoryTags = categoryTagsForQuery(queryLower);
        for (final tag in categoryTags) {
          try {
            final categoryResults = await widget.offClient.searchProducts(query, categoryTag: tag);
            if (categoryResults.isNotEmpty) {
              effectiveResults = categoryResults;
              break;
            }
          } catch (_) {}
        }
      }

      final filteredResults = effectiveResults.where((result) => _isEnglishResult(result.product)).toList();
      final preferredResults = filteredResults.isEmpty ? effectiveResults : filteredResults;
      final candidates = <_OffSearchCandidate>[];
      for (final result in preferredResults) {
        final item = _offMapper.mapProduct(
          product: result.product,
          rawJson: result.rawJson,
          localeLanguage: locale,
        );
        if (item.barcode == null || item.barcode!.isEmpty) continue;
        candidates.add(_OffSearchCandidate(item: item, product: result.product));
      }
      final narrowedCandidates = _preferWholeFoodCandidates(candidates, queryLower);
      final items = narrowedCandidates.map((c) => c.item).toList();
      items.sort((a, b) => _nameMatchScore(b.name, queryLower) - _nameMatchScore(a.name, queryLower));
      if (!mounted) return;
      if (_searchController.text.trim() != query) {
        setState(() => _isOffLoading = false);
        return;
      }
      setState(() {
        _offResults = items;
        _isOffLoading = false;
        if (items.isEmpty) {
          _message = 'No OpenFoodFacts matches found.';
          _messageTone = InlineBannerTone.info;
        }
      });
      if (items.isEmpty) return;
      final stored = await _ingestOffResults(items);
      if (!mounted) return;
      if (_searchController.text.trim() != query) return;
      setState(() {
        _offResults = stored;
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

  Future<List<FoodItem>> _ingestOffResults(List<FoodItem> items) async {
    final stored = <FoodItem>[];
    for (final item in items) {
      try {
        stored.add((await widget.foodsApi.ingestFood(item)).item);
      } on ApiException catch (error) {
        if (error.isUnauthorized) {
          await widget.onLogout();
          return stored.isEmpty ? items : stored;
        }
        stored.add(item);
      }
    }
    return stored;
  }

  Future<FoodItem?> _tryUploadImages(FoodItem item) async {
    final backendId = item.backendId;
    final largeUrl = item.offImageLargeUrl;
    final smallUrl = item.offImageSmallUrl;
    if (backendId == null || largeUrl == null || smallUrl == null) return null;
    final large = await _imageDownloader.downloadImage(largeUrl);
    final small = await _imageDownloader.downloadImage(smallUrl);
    if (large == null || small == null) return null;
    return widget.foodsApi.uploadFoodImages(
      foodItemId: backendId,
      largeBytes: large.bytes,
      smallBytes: small.bytes,
      largeContentType: large.contentType,
      smallContentType: small.contentType,
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

      for (FoodItem selected in _addedItems) {
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
          quantityG: 100, // Hardcoded for now
          consumedAt: consumedAt,
        );

        if (selected.localId != null) {
          await widget.localDb.updateLastUsed(selected.localId!, consumedAt);
        }
      }

      if (!mounted) return;
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
    if (item.barcode != null && item.barcode!.isNotEmpty) return 'barcode:${item.barcode}';
    if (item.backendId != null) return 'backend:${item.backendId}';
    if (item.externalId.isNotEmpty) return 'external:${item.externalId}';
    return null;
  }

  bool _isEnglishResult(Map<String, dynamic> product) {
    final lang = product['lang'];
    if (lang is String && lang.toLowerCase() == 'en') return true;
    final nameEn = product['product_name_en'];
    if (nameEn is String && nameEn.trim().isNotEmpty) return true;
    return false;
  }

  bool _hasCategoryMatch(List<OffProductResponse> results, String queryLower) {
    for (final result in results) {
      if (_matchesCategoryQuery(result.product, queryLower)) return true;
    }
    return false;
  }

  List<_OffSearchCandidate> _preferWholeFoodCandidates(List<_OffSearchCandidate> candidates, String queryLower) {
    if (candidates.isEmpty || queryLower.contains(' ')) return candidates;
    final categoryMatches = candidates.where((c) => _matchesCategoryQuery(c.product, queryLower)).toList();
    if (categoryMatches.isNotEmpty) return categoryMatches;
    final nameMatches = candidates.where((c) => _isSimpleNameMatch(c.item.name, queryLower)).toList();
    if (nameMatches.isNotEmpty) return nameMatches;
    return candidates;
  }

  bool _matchesCategoryQuery(Map<String, dynamic> product, String queryLower) {
    final tags = product['categories_tags'];
    if (tags is! List) return false;
    final singular = queryLower;
    final plural = queryLower.endsWith('s') ? queryLower : '${queryLower}s';
    for (final tag in tags) {
      if (tag is! String) continue;
      final lower = tag.toLowerCase();
      if (lower == 'en:$singular' || lower == 'en:$plural') return true;
    }
    return false;
  }

  bool _isSimpleNameMatch(String name, String queryLower) {
    final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').trim();
    if (normalized == queryLower || normalized == '${queryLower}s') return true;
    final parts = normalized.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
    if (parts.isEmpty || parts.length > 2) return false;
    return parts.contains(queryLower);
  }

  int _nameMatchScore(String name, String queryLower) {
    if (queryLower.isEmpty) return 0;
    final nameLower = name.toLowerCase();
    int score = 0;
    if (nameLower == queryLower) score += 400;
    if (nameLower.startsWith(queryLower)) score += 300;
    final wordMatch = RegExp(r'\b' + RegExp.escape(queryLower)).hasMatch(nameLower);
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
      case _FoodResultOrigin.off: score += 5; break;
      case _FoodResultOrigin.backend: score += 3; break;
      case _FoodResultOrigin.local: score += 1; break;
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

    // Calculate totals based on 100g per selected item for now
    double totalEnergy = 0;
    double totalProtein = 0;
    double totalCarbs = 0;
    double totalFats = 0;

    for (final item in _addedItems) {
      totalEnergy += item.kcal100g ?? 0.0;
      totalProtein += item.proteinG100g ?? 0.0;
      totalCarbs += item.carbsG100g ?? 0.0;
      totalFats += item.fatG100g ?? 0.0;
    }
    
    final mealLabel = _selectedMeal.name[0].toUpperCase() + _selectedMeal.name.substring(1);

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface.withValues(alpha: 0.8),
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ColorFilter.mode(Colors.black.withValues(alpha: 0.1), BlendMode.dstOut),
            // Use flutter standard BackdropFilter if we had a child
            child: Container(color: Colors.transparent),
          ),
        ),
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: scheme.primary),
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
            icon: Icon(Icons.check, color: canSubmit ? scheme.primary : scheme.outlineVariant),
            onPressed: canSubmit ? _submitItems : null,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Meal Type Selector
            InkWell(
              onTap: _showMealSelector,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
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
                        _MacroSummaryRow(label: 'Protein', value: '${totalProtein.round()}g', color: scheme.secondary, progress: 0.7),
                        _MacroSummaryRow(label: 'Carbs', value: '${totalCarbs.round()}g', color: scheme.tertiary, progress: 0.5),
                        _MacroSummaryRow(label: 'Fats', value: '${totalFats.round()}g', color: scheme.primary, progress: 0.25),
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
                final item = entry.value;
                final kcal = item.kcal100g?.round() ?? 0;
                return Container(
                  margin: const EdgeInsets.only(bottom: AppSpacing.xs),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '100g • $kcal kcal',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.remove_circle, color: scheme.error),
                        onPressed: () => _removeItem(index),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                );
              }),
            ],
            
            const SizedBox(height: AppSpacing.lg),

            // Search Bar
            if (_message != null) ...[
              InlineBanner(message: _message!, tone: _messageTone ?? InlineBannerTone.info),
              const SizedBox(height: AppSpacing.md),
            ],
            GlassSearchBar(
              controller: _searchController,
              onScan: _isOffRateLimited ? null : _openScanPage,
            ),
            if (hasQuery) ...[
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _isOffLoading || _isOffRateLimited ? null : _searchOnline,
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.secondary,
                  ),
                  icon: const Icon(Icons.public),
                  label: const Text('Search online'),
                ),
              ),
            ],
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
                           _selectedFilter == _filterFavorites ? _filterRecent : _filterFavorites
                         );
                      },
                      child: Text(
                        _selectedFilter == _filterFavorites ? 'View Recent' : 'View Favorites',
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
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(
                  child: Text(
                    'No foods found.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
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
                    onTap: () => _appendResult(item.item),
                  );
                },
              ),
              
            const SizedBox(height: 100), // padding for bottom nav space if any
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

enum MealType { breakfast, lunch, dinner, snacks }
enum _FoodResultOrigin { local, backend, off }

class _FoodResult {
  const _FoodResult({
    required this.item,
    required this.origin,
  });

  final FoodItem item;
  final _FoodResultOrigin origin;
}

class _OffSearchCandidate {
  const _OffSearchCandidate({
    required this.item,
    required this.product,
  });

  final FoodItem item;
  final Map<String, dynamic> product;
}

class _FoodCard extends StatelessWidget {
  const _FoodCard({
    required this.item,
    required this.onTap,
  });

  final _FoodResult item;
  final VoidCallback onTap;

  IconData _originIcon(_FoodResultOrigin origin) {
    switch (origin) {
      case _FoodResultOrigin.local: return Icons.history;
      case _FoodResultOrigin.backend: return Icons.cloud;
      case _FoodResultOrigin.off: return Icons.public;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(AppRadius.lg * 1.5);
    
    final kcal = item.item.kcal100g?.round();
    final kcalLabel = kcal == null ? 'kcal n/a' : '$kcal kcal / 100g';
    final primaryUrl = item.item.imageUrl?.trim();
    final fallbackSmall = item.item.offImageSmallUrl?.trim();
    final fallbackLarge = item.item.offImageLargeUrl?.trim();
    final imageUrl = (primaryUrl != null && primaryUrl.isNotEmpty)
        ? primaryUrl
        : (fallbackSmall != null && fallbackSmall.isNotEmpty)
            ? fallbackSmall
            : (fallbackLarge != null && fallbackLarge.isNotEmpty)
                ? fallbackLarge
                : null;
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: radius,
            border: Border.all(color: Colors.transparent),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasImage) ...[
                  ColorFiltered(
                    colorFilter: const ColorFilter.mode(
                      Colors.grey,
                      BlendMode.saturation,
                    ),
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                    ),
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
    );
  }
}
