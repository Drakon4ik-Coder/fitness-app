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
import 'data/off_mapper.dart';
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

  MealType _selectedMeal = MealType.breakfast;
  String _selectedFilter = _filterRecent;
  int? _selectedResultIndex;

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
    _searchController.dispose();
    super.dispose();
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
        _selectedResultIndex = null;
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
      _selectedResultIndex = null;
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
      _selectedResultIndex = null;
    });
  }

  Future<void> _loadLocalSearch(String query) async {
    final results = await widget.localDb.searchFoods(query);
    if (!mounted) {
      return;
    }
    setState(() {
      _localResults = results;
      _selectedResultIndex = null;
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
      final stored = await widget.localDb.upsertFoods(results);
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
        _backendResults = stored;
        _isBackendLoading = false;
        _selectedResultIndex = null;
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

  void _selectResult(int index) {
    setState(() {
      _selectedResultIndex = index;
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
      final item = _offMapper.mapProduct(
        product: response.product,
        rawJson: response.rawJson,
      );
      final stored = await widget.localDb.upsertFood(item);
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
        _offResults = [stored];
        _backendResults = [];
        _localResults = [];
        _isOffLoading = false;
        _selectedResultIndex = 0;
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
    final queryLower = query.toLowerCase();
    setState(() {
      _isOffLoading = true;
      _message = null;
      _messageTone = null;
    });
    try {
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
      final stored = await widget.localDb.upsertFoods(items);
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
        _offResults = stored;
        _isOffLoading = false;
        _selectedResultIndex = null;
        if (stored.isEmpty) {
          _message = 'No OpenFoodFacts matches found.';
          _messageTone = InlineBannerTone.info;
        }
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

  Future<void> _addSelected(List<_FoodResult> results) async {
    if (_selectedResultIndex == null) {
      return;
    }
    final index = _selectedResultIndex!;
    if (index < 0 || index >= results.length) {
      return;
    }
    setState(() {
      _isSubmitting = true;
      _message = null;
      _messageTone = null;
    });

    FoodItem selected = results[index].item;
    try {
      if (selected.backendId == null) {
        final ingested = await widget.foodsApi.ingestFood(selected);
        if (selected.localId != null && ingested.backendId != null) {
          await widget.localDb.updateBackendId(
            selected.localId!,
            ingested.backendId!,
          );
          selected = ingested.copyWith(localId: selected.localId);
        } else {
          selected = await widget.localDb.upsertFood(ingested);
        }
      }
      if (selected.backendId == null) {
        throw ApiException('Unable to resolve food item id.');
      }

      final consumedAt = DateTime(
        widget.selectedDate.year,
        widget.selectedDate.month,
        widget.selectedDate.day,
        DateTime.now().hour,
        DateTime.now().minute,
      );

      await widget.nutritionApi.createEntry(
        foodItemId: selected.backendId!,
        mealType: _selectedMeal.name,
        quantityG: 100,
        consumedAt: consumedAt,
      );

      if (selected.localId != null) {
        await widget.localDb.updateLastUsed(selected.localId!, consumedAt);
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
      return 'Search results';
    }
    if (_selectedFilter == _filterFavorites) {
      return 'Favorites';
    }
    return 'Recent foods';
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
    final query = _searchController.text;
    final results = _buildResults(query);
    final hasQuery = query.trim().isNotEmpty;
    final canAdd = !_isSubmitting && _selectedResultIndex != null;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      builder: (context, scrollController) {
        return Material(
          color: scheme.surface,
          child: Padding(
            padding: EdgeInsets.only(
              left: AppSpacing.lg,
              right: AppSpacing.lg,
              top: AppSpacing.lg,
              bottom: AppSpacing.lg + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add food',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Choose meal',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<MealType>(
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      backgroundColor: MaterialStateProperty.resolveWith(
                        (states) => states.contains(MaterialState.selected)
                            ? scheme.primaryContainer
                            : scheme.surfaceContainer,
                      ),
                      foregroundColor: MaterialStateProperty.resolveWith(
                        (states) => states.contains(MaterialState.selected)
                            ? scheme.onPrimaryContainer
                            : scheme.onSurface,
                      ),
                      side: MaterialStateProperty.all(
                        BorderSide(color: scheme.outlineVariant),
                      ),
                    ),
                    segments: const [
                      ButtonSegment(
                        value: MealType.breakfast,
                        label: Text('Breakfast'),
                      ),
                      ButtonSegment(
                        value: MealType.lunch,
                        label: Text('Lunch'),
                      ),
                      ButtonSegment(
                        value: MealType.dinner,
                        label: Text('Dinner'),
                      ),
                      ButtonSegment(
                        value: MealType.snacks,
                        label: Text('Snacks'),
                      ),
                    ],
                    selected: {_selectedMeal},
                    onSelectionChanged: (selection) {
                      if (selection.isEmpty) {
                        return;
                      }
                      _selectMeal(selection.first);
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                _SearchBarGroup(
                  controller: _searchController,
                  onScan: _openScanPage,
                ),
                if (hasQuery) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _isOffLoading ? null : _searchOnline,
                      icon: const Icon(Icons.public),
                      label: const Text('Search online (OpenFoodFacts)'),
                    ),
                  ),
                ],
                if (!hasQuery) ...[
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      _FilterChip(
                        label: _filterRecent,
                        isSelected: _selectedFilter == _filterRecent,
                        onSelected: () => _selectFilter(_filterRecent),
                      ),
                      _FilterChip(
                        label: _filterFavorites,
                        isSelected: _selectedFilter == _filterFavorites,
                        onSelected: () => _selectFilter(_filterFavorites),
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
                const SizedBox(height: AppSpacing.lg),
                Expanded(
                  child: CustomScrollView(
                    controller: scrollController,
                    slivers: [
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _resultsHeading(query),
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            if (_isBackendLoading || _isOffLoading)
                              LinearProgressIndicator(
                                minHeight: 2,
                                color: scheme.primary,
                              ),
                            const SizedBox(height: AppSpacing.sm),
                          ],
                        ),
                      ),
                      if (results.isEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: AppSpacing.lg,
                            ),
                            child: Text('No foods to show yet.'),
                          ),
                        )
                      else
                        SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: AppSpacing.sm,
                            crossAxisSpacing: AppSpacing.sm,
                            childAspectRatio: 1.2,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final item = results[index];
                              final bool isSelected = _selectedResultIndex == index;
                              return _FoodResultTile(
                                item: item,
                                isSelected: isSelected,
                                onTap: () => _selectResult(index),
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
                  child: SizedBox(
                    width: double.infinity,
                    child: AppPrimaryButton(
                      onPressed:
                          canAdd ? () => _addSelected(results) : null,
                      isLoading: _isSubmitting,
                      child: const Text('Add selected'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.isSelected,
    required this.onSelected,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final labelColor =
        isSelected ? scheme.onPrimaryContainer : scheme.onSurface;
    return FilterChip(
      label: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(color: labelColor),
      ),
      selected: isSelected,
      onSelected: (_) => onSelected(),
      selectedColor: scheme.primaryContainer,
      backgroundColor: scheme.surfaceContainer,
      side: BorderSide(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
      ),
      showCheckmark: false,
    );
  }
}

class _SearchBarGroup extends StatelessWidget {
  const _SearchBarGroup({
    required this.controller,
    required this.onScan,
  });

  final TextEditingController controller;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: IconButton(
                tooltip: 'Scan barcode',
                onPressed: onScan,
                style: IconButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                ),
                icon: const Icon(Icons.qr_code_scanner),
              ),
            ),
            Container(
              width: 1,
              height: 32,
              color: scheme.outlineVariant.withValues(alpha: 0.7),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  labelText: 'Search foods',
                  floatingLabelBehavior: FloatingLabelBehavior.never,
                  border: InputBorder.none,
                  isDense: true,
                  filled: false,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final hasText = value.text.trim().isNotEmpty;
                if (hasText) {
                  return SizedBox(
                    width: 48,
                    child: IconButton(
                      tooltip: 'Clear search',
                      onPressed: controller.clear,
                      style: IconButton.styleFrom(
                        foregroundColor: scheme.onSurfaceVariant,
                      ),
                      icon: const Icon(Icons.close),
                    ),
                  );
                }
                return SizedBox(
                  width: 48,
                  child: Center(
                    child: Icon(
                      Icons.search,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ],
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
    final background = isSelected
        ? scheme.primaryContainer
        : scheme.surfaceContainerHigh;
    final contentColor =
        isSelected ? scheme.onPrimaryContainer : scheme.onSurface;
    final metaColor = isSelected
        ? scheme.onPrimaryContainer.withValues(alpha: 0.75)
        : scheme.onSurfaceVariant;
    final mediaColor = isSelected
        ? scheme.surfaceContainerLowest
        : scheme.surfaceContainerLow;

    final kcal = item.item.kcal100g?.round();
    final kcalLabel = kcal == null ? 'kcal n/a' : '$kcal kcal/100g';
    final originLabel = _originLabel(item.origin);
    final brandLabel = item.item.brands.trim();
    final metaLabel = brandLabel.isNotEmpty
        ? '$brandLabel - $kcalLabel'
        : '$originLabel - $kcalLabel';
    final imageUrl = item.item.imageUrl?.trim();
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
    const double imageSize = 56;

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: onTap,
      child: Ink(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: isSelected
                ? scheme.outlineVariant.withValues(alpha: 0.8)
                : scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: SizedBox.square(
                    dimension: imageSize,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(
                          color: mediaColor,
                          child: Icon(
                            _originIcon(item.origin),
                            color: contentColor,
                            size: 24,
                          ),
                        ),
                        if (hasImage)
                          Image.network(
                            imageUrl,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.medium,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                            loadingBuilder: (context, child, progress) {
                              if (progress == null) {
                                return child;
                              }
                              return const SizedBox.shrink();
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                item.item.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: contentColor,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                metaLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: metaColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
