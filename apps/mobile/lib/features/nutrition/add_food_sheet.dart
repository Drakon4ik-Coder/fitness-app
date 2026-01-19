import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui_components/ui_components.dart';
import '../../ui_system/pulse_theme.dart';
import '../../ui_system/tokens.dart';
import 'data/api_exceptions.dart';
import 'data/food_local_db.dart';
import 'data/food_models.dart';
import 'data/foods_api_service.dart';
import 'data/nutrition_api_service.dart';
import 'data/off_client.dart';
import 'data/off_mapper.dart';
import 'data/off_rate_limiter.dart';
import 'nutrition_scan_page.dart';

const String _filterRecent = 'Recent';
const String _filterFavorites = 'Favorites';

class AddFoodSheet extends StatefulWidget {
  const AddFoodSheet({
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
  State<AddFoodSheet> createState() => _AddFoodSheetState();
}

class _AddFoodSheetState extends State<AddFoodSheet> {
  final TextEditingController _searchController = TextEditingController();
  final OffMapper _offMapper = OffMapper();
  Timer? _debounce;
  Timer? _offBlockTimer;

  static const Duration _scanCooldown = Duration(seconds: 3);
  DateTime? _offBlockedUntil;
  String? _lastScannedBarcode;
  DateTime? _lastScannedAt;

  MealType _selectedMeal = MealType.breakfast;
  String _selectedFilter = _filterRecent;
  final Set<int> _selectedResultIndices = <int>{};

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
    if (until == null) {
      return false;
    }
    return until.isAfter(DateTime.now());
  }

  void _applyOffLimit(OffRateLimitException error) {
    final until = DateTime.now().add(error.retryAfter);
    _offBlockedUntil = until;
    _offBlockTimer?.cancel();
    if (error.retryAfter > Duration.zero) {
      _offBlockTimer = Timer(error.retryAfter, () {
        if (!mounted) {
          return;
        }
        setState(() {
          _offBlockedUntil = null;
        });
      });
    }
  }

  void _handleSearchChange() {
    if (_ignoreSearchChange) {
      return;
    }
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      _debounce?.cancel();
      setState(() {
        _backendResults = [];
        _offResults = [];
        _selectedResultIndices.clear();
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
      _selectedResultIndices.clear();
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
    if (query.isNotEmpty) {
      return;
    }
    final results = _selectedFilter == _filterFavorites
        ? await widget.localDb.fetchFavorites()
        : await widget.localDb.fetchRecentFoods();
    if (!mounted) {
      return;
    }
    setState(() {
      _localResults = results;
      _selectedResultIndices.clear();
    });
  }

  Future<void> _loadLocalSearch(String query) async {
    final results = await widget.localDb.searchFoods(query);
    if (!mounted) {
      return;
    }
    setState(() {
      _localResults = results;
      _selectedResultIndices.clear();
    });
  }

  Future<void> _loadBackendSearch(String query) async {
    if (!mounted) {
      return;
    }
    setState(() {
      _isBackendLoading = true;
      _message = null;
      _messageTone = null;
    });
    try {
      final results = await widget.foodsApi.typeahead(query);
      if (!mounted) {
        return;
      }
      if (_searchController.text.trim() != query) {
        setState(() {
          _isBackendLoading = false;
        });
        return;
      }
      setState(() {
        _backendResults = results;
        _isBackendLoading = false;
        _selectedResultIndices.clear();
      });
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await widget.onLogout();
        if (!mounted) {
          return;
        }
        setState(() {
          _isBackendLoading = false;
        });
        return;
      }
      if (!mounted) {
        return;
      }
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
    if (_selectedFilter == filter) {
      return;
    }
    setState(() {
      _selectedFilter = filter;
    });
    _loadFilterResults();
  }

  void _toggleResult(int index) {
    setState(() {
      if (_selectedResultIndices.contains(index)) {
        _selectedResultIndices.remove(index);
      } else {
        _selectedResultIndices.add(index);
      }
    });
  }

  Future<void> _openScanPage() async {
    FocusScope.of(context).unfocus();
    final barcode = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const NutritionScanPage(),
      ),
    );
    if (barcode == null || barcode.trim().isEmpty) {
      return;
    }
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
      if (!mounted) {
        return;
      }
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
      if (!mounted) {
        return;
      }
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
        _selectedResultIndices
          ..clear()
          ..add(0);
      });
    } on OffRateLimitException catch (error) {
      if (!mounted) {
        return;
      }
      _applyOffLimit(error);
      setState(() {
        _isOffLoading = false;
        _message = error.message;
        _messageTone = InlineBannerTone.info;
      });
    } on OffException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isOffLoading = false;
        _message = error.message;
        _messageTone = InlineBannerTone.error;
      });
    }
  }

  Future<void> _searchOnline() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      return;
    }
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
      final bool hasCategoryMatch =
          _hasCategoryMatch(baseResults, queryLower);
      if (baseResults.isEmpty || !hasCategoryMatch) {
        final categoryTags = _categoryTagsForQuery(queryLower);
        for (final tag in categoryTags) {
          try {
            final categoryResults = await widget.offClient.searchProducts(
              query,
              categoryTag: tag,
            );
            if (categoryResults.isNotEmpty) {
              effectiveResults = categoryResults;
              break;
            }
          } catch (_) {
            // Keep base results if category search fails.
          }
        }
      }

      final filteredResults = effectiveResults
          .where((result) => _isEnglishResult(result.product))
          .toList();
      final preferredResults =
          filteredResults.isEmpty ? effectiveResults : filteredResults;
      final candidates = <_OffSearchCandidate>[];
      for (final result in preferredResults) {
        final item = _offMapper.mapProduct(
          product: result.product,
          rawJson: result.rawJson,
          localeLanguage: locale,
        );
        if (item.barcode == null || item.barcode!.isEmpty) {
          continue;
        }
        candidates.add(
          _OffSearchCandidate(item: item, product: result.product),
        );
      }
      final narrowedCandidates =
          _preferWholeFoodCandidates(candidates, queryLower);
      final items = narrowedCandidates.map((candidate) => candidate.item).toList();
      items.sort(
        (a, b) =>
            _nameMatchScore(b.name, queryLower) -
            _nameMatchScore(a.name, queryLower),
      );
      if (!mounted) {
        return;
      }
      if (_searchController.text.trim() != query) {
        setState(() {
          _isOffLoading = false;
        });
        return;
      }
      setState(() {
        _offResults = items;
        _isOffLoading = false;
        _selectedResultIndices.clear();
        if (items.isEmpty) {
          _message = 'No OpenFoodFacts matches found.';
          _messageTone = InlineBannerTone.info;
        }
      });
      if (items.isEmpty) {
        return;
      }
      final stored = await _ingestOffResults(items);
      if (!mounted) {
        return;
      }
      if (_searchController.text.trim() != query) {
        return;
      }
      setState(() {
        _offResults = stored;
      });
    } on OffRateLimitException catch (error) {
      if (!mounted) {
        return;
      }
      _applyOffLimit(error);
      setState(() {
        _isOffLoading = false;
        _message = error.message;
        _messageTone = InlineBannerTone.info;
      });
    } on OffException catch (error) {
      if (!mounted) {
        return;
      }
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
        stored.add(await widget.foodsApi.ingestFood(item));
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

  Future<void> _addSelected(List<_FoodResult> results) async {
    if (_selectedResultIndices.isEmpty) {
      return;
    }
    final indices = _selectedResultIndices.toList()..sort();
    setState(() {
      _isSubmitting = true;
      _message = null;
      _messageTone = null;
    });

    try {
      final consumedAt = DateTime(
        widget.selectedDate.year,
        widget.selectedDate.month,
        widget.selectedDate.day,
        DateTime.now().hour,
        DateTime.now().minute,
      );

      for (final index in indices) {
        if (index < 0 || index >= results.length) {
          continue;
        }
        FoodItem selected = results[index].item;
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
            } else {
              selected = await widget.foodsApi.ingestFood(selected);
            }
          } else {
            selected = await widget.foodsApi.ingestFood(selected);
          }
        }
        if (selected.backendId == null) {
          throw ApiException('Unable to resolve food item id.');
        }

        final stored = await widget.localDb.upsertFood(selected);
        selected = stored;

        await widget.nutritionApi.createEntry(
          foodItemId: selected.backendId!,
          mealType: _selectedMeal.name,
          quantityG: 100,
          consumedAt: consumedAt,
        );

        if (selected.localId != null) {
          await widget.localDb.updateLastUsed(selected.localId!, consumedAt);
        }
      }

      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await widget.onLogout();
        if (!mounted) {
          return;
        }
        setState(() {
          _isSubmitting = false;
        });
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _isSubmitting = false;
        _message = error.message;
        _messageTone = InlineBannerTone.error;
      });
    }
  }

  String _resultsHeading(String query) {
    final trimmed = query.trim();
    if (trimmed.isNotEmpty) {
      return 'Search Results';
    }
    if (_selectedFilter == _filterFavorites) {
      return 'Favorites';
    }
    return 'Recent Foods';
  }

  List<_FoodResult> _buildResults(String query) {
    final trimmed = query.trim();
    final results = <_FoodResult>[];
    final seenKeys = <String>{};

    void addItems(List<FoodItem> items, _FoodResultOrigin origin) {
      for (final item in items) {
        final key = _resultKey(item);
        if (key == null || seenKeys.contains(key)) {
          continue;
        }
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
      if (scoreA != scoreB) {
        return scoreB.compareTo(scoreA);
      }
      final lengthCompare = a.item.name.length.compareTo(b.item.name.length);
      if (lengthCompare != 0) {
        return lengthCompare;
      }
      return a.item.name.compareTo(b.item.name);
    });
    return results;
  }

  String? _resultKey(FoodItem item) {
    if (item.barcode != null && item.barcode!.isNotEmpty) {
      return 'barcode:${item.barcode}';
    }
    if (item.backendId != null) {
      return 'backend:${item.backendId}';
    }
    if (item.externalId.isNotEmpty) {
      return 'external:${item.externalId}';
    }
    return null;
  }

  bool _isEnglishResult(Map<String, dynamic> product) {
    final lang = product['lang'];
    if (lang is String && lang.toLowerCase() == 'en') {
      return true;
    }
    final nameEn = product['product_name_en'];
    if (nameEn is String && nameEn.trim().isNotEmpty) {
      return true;
    }
    return false;
  }

  bool _hasCategoryMatch(
    List<OffProductResponse> results,
    String queryLower,
  ) {
    for (final result in results) {
      if (_matchesCategoryQuery(result.product, queryLower)) {
        return true;
      }
    }
    return false;
  }

  List<String> _categoryTagsForQuery(String queryLower) {
    final trimmed = queryLower.trim();
    if (trimmed.isEmpty || trimmed.contains(' ')) {
      return const [];
    }
    final normalized =
        trimmed.replaceAll(RegExp(r'[^a-z0-9]+'), '-').trim();
    if (normalized.isEmpty) {
      return const [];
    }
    final tags = <String>{'en:$normalized'};
    if (!normalized.endsWith('s')) {
      tags.add('en:${normalized}s');
    }
    return tags.toList();
  }

  List<_OffSearchCandidate> _preferWholeFoodCandidates(
    List<_OffSearchCandidate> candidates,
    String queryLower,
  ) {
    if (candidates.isEmpty || queryLower.contains(' ')) {
      return candidates;
    }
    final categoryMatches = candidates
        .where((candidate) => _matchesCategoryQuery(candidate.product, queryLower))
        .toList();
    if (categoryMatches.isNotEmpty) {
      return categoryMatches;
    }
    final nameMatches = candidates
        .where((candidate) => _isSimpleNameMatch(candidate.item.name, queryLower))
        .toList();
    if (nameMatches.isNotEmpty) {
      return nameMatches;
    }
    return candidates;
  }

  bool _matchesCategoryQuery(Map<String, dynamic> product, String queryLower) {
    final tags = product['categories_tags'];
    if (tags is! List) {
      return false;
    }
    final singular = queryLower;
    final plural = queryLower.endsWith('s') ? queryLower : '${queryLower}s';
    for (final tag in tags) {
      if (tag is! String) {
        continue;
      }
      final lower = tag.toLowerCase();
      if (lower == 'en:$singular' || lower == 'en:$plural') {
        return true;
      }
    }
    return false;
  }

  bool _isSimpleNameMatch(String name, String queryLower) {
    final normalized =
        name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').trim();
    if (normalized == queryLower || normalized == '${queryLower}s') {
      return true;
    }
    final parts = normalized
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty || parts.length > 2) {
      return false;
    }
    return parts.contains(queryLower);
  }

  int _nameMatchScore(String name, String queryLower) {
    if (queryLower.isEmpty) {
      return 0;
    }
    final nameLower = name.toLowerCase();
    int score = 0;
    if (nameLower == queryLower) {
      score += 400;
    }
    if (nameLower.startsWith(queryLower)) {
      score += 300;
    }
    final wordMatch =
        RegExp(r'\b' + RegExp.escape(queryLower)).hasMatch(nameLower);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final effects = PulseTheme.effectsOf(context);
    final query = _searchController.text;
    final results = _buildResults(query);
    final hasQuery = query.trim().isNotEmpty;
    final canAdd = !_isSubmitting && _selectedResultIndices.isNotEmpty;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      builder: (context, scrollController) {
        return Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  scheme.surface,
                  scheme.surfaceContainer,
                  scheme.surfaceContainerHigh,
                ],
              ),
            ),
            child: Padding(
              padding: EdgeInsets.only(
                left: AppSpacing.lg,
                right: AppSpacing.lg,
                top: AppSpacing.lg,
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Add Food',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  GlassSearchBar(
                    controller: _searchController,
                    onScan: _isOffRateLimited ? null : _openScanPage,
                  ),
                  if (hasQuery) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _isOffLoading || _isOffRateLimited
                            ? null
                            : _searchOnline,
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.secondary,
                        ),
                        icon: const Icon(Icons.public),
                        label: const Text('Search online (OpenFoodFacts)'),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    'Choose meal',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      _PulseChip(
                        label: 'Breakfast',
                        isSelected: _selectedMeal == MealType.breakfast,
                        accentColor: scheme.primary,
                        onTap: () => _selectMeal(MealType.breakfast),
                        glowSigma: effects.glowLow,
                      ),
                      _PulseChip(
                        label: 'Lunch',
                        isSelected: _selectedMeal == MealType.lunch,
                        accentColor: scheme.primary,
                        onTap: () => _selectMeal(MealType.lunch),
                        glowSigma: effects.glowLow,
                      ),
                      _PulseChip(
                        label: 'Dinner',
                        isSelected: _selectedMeal == MealType.dinner,
                        accentColor: scheme.primary,
                        onTap: () => _selectMeal(MealType.dinner),
                        glowSigma: effects.glowLow,
                      ),
                      _PulseChip(
                        label: 'Snacks',
                        isSelected: _selectedMeal == MealType.snacks,
                        accentColor: scheme.primary,
                        onTap: () => _selectMeal(MealType.snacks),
                        glowSigma: effects.glowLow,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    _resultsHeading(query),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                  if (!hasQuery) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.xs,
                      children: [
                        _PulseChip(
                          label: _filterRecent,
                          isSelected: _selectedFilter == _filterRecent,
                          accentColor: scheme.secondary,
                          onTap: () => _selectFilter(_filterRecent),
                          glowSigma: effects.glowLow,
                        ),
                        _PulseChip(
                          label: _filterFavorites,
                          isSelected: _selectedFilter == _filterFavorites,
                          accentColor: scheme.secondary,
                          onTap: () => _selectFilter(_filterFavorites),
                          glowSigma: effects.glowLow,
                        ),
                      ],
                    ),
                  ],
                  if (_message != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    InlineBanner(
                      message: _message!,
                      tone: _messageTone ?? InlineBannerTone.info,
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
                  const SizedBox(height: AppSpacing.md),
                  Expanded(
                    child: CustomScrollView(
                      controller: scrollController,
                      slivers: [
                        if (results.isEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: AppSpacing.lg,
                              ),
                              child: Text(
                                'No foods to show yet.',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          )
                        else
                          SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: AppSpacing.sm,
                              crossAxisSpacing: AppSpacing.sm,
                              childAspectRatio: 0.95,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final item = results[index];
                                final bool isSelected =
                                    _selectedResultIndices.contains(index);
                                return _FoodResultTile(
                                  item: item,
                                  isSelected: isSelected,
                                  onTap: () => _toggleResult(index),
                                );
                              },
                              childCount: results.length,
                            ),
                          ),
                        const SliverToBoxAdapter(
                          child: SizedBox(height: AppSpacing.lg),
                        ),
                      ],
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        top: AppSpacing.md,
                        bottom: AppSpacing.lg,
                      ),
                      child: NeonPillButton(
                        onPressed: canAdd ? () => _addSelected(results) : null,
                        isLoading: _isSubmitting,
                        child: const Text('Add Selected'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PulseChip extends StatelessWidget {
  const _PulseChip({
    required this.label,
    required this.isSelected,
    required this.accentColor,
    required this.onTap,
    required this.glowSigma,
  });

  final String label;
  final bool isSelected;
  final Color accentColor;
  final VoidCallback onTap;
  final double glowSigma;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background = isSelected
        ? accentColor.withValues(alpha: 0.18)
        : scheme.surfaceContainerHigh.withValues(alpha: 0.6);
    final borderColor = isSelected
        ? accentColor.withValues(alpha: 0.8)
        : scheme.outlineVariant.withValues(alpha: 0.6);
    final labelColor =
        isSelected ? scheme.onSurface : scheme.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          constraints: const BoxConstraints(minHeight: 48),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor),
            boxShadow: [
              if (isSelected)
                BoxShadow(
                  color: accentColor.withValues(alpha: 0.45),
                  blurRadius: glowSigma,
                  spreadRadius: 1,
                ),
            ],
          ),
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: labelColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
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

class _FoodResultTile extends StatelessWidget {
  const _FoodResultTile({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  final _FoodResult item;
  final bool isSelected;
  final VoidCallback onTap;

  String _originLabel(_FoodResultOrigin origin) {
    switch (origin) {
      case _FoodResultOrigin.local:
        return 'Saved';
      case _FoodResultOrigin.backend:
        return 'Backend';
      case _FoodResultOrigin.off:
        return 'OpenFoodFacts';
    }
  }

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
    final effects = PulseTheme.effectsOf(context);
    final radius = BorderRadius.circular(AppRadius.lg);
    final borderColor = isSelected
        ? scheme.primary.withValues(alpha: 0.9)
        : scheme.outlineVariant.withValues(alpha: 0.6);

    final kcal = item.item.kcal100g?.round();
    final kcalLabel = kcal == null ? 'kcal n/a' : '$kcal kcal/100g';
    final originLabel = _originLabel(item.origin);
    final brandLabel = item.item.brands.trim();
    final metaLabel = brandLabel.isNotEmpty
        ? '$brandLabel - $kcalLabel'
        : '$originLabel - $kcalLabel';
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
            borderRadius: radius,
            border: Border.all(color: borderColor),
            boxShadow: [
              if (isSelected)
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.35),
                  blurRadius: effects.glowLow,
                  spreadRadius: 1,
                ),
            ],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasImage)
                  Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (_, error, stackTrace) =>
                        const SizedBox.shrink(),
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) {
                        return child;
                      }
                      return const SizedBox.shrink();
                    },
                  )
                else
                  Container(
                    color: scheme.surfaceContainerHigh,
                    child: Icon(
                      _originIcon(item.origin),
                      color: scheme.onSurfaceVariant,
                      size: 28,
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
                          Colors.black.withValues(alpha: 0.7),
                        ],
                      ),
                    ),
                  ),
                ),
                if (isSelected)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.12),
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
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        metaLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white70,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  Positioned(
                    top: AppSpacing.sm,
                    right: AppSpacing.sm,
                    child: Icon(
                      Icons.check_circle,
                      color: scheme.primary,
                      size: 22,
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
