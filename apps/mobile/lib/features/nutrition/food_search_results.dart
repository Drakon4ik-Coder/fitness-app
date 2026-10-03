import 'data/food_models.dart';

/// How the add-food page merges its four result sources into one ranked list
/// (KAN-124: extracted from `add_food_page.dart` so the ranking rules are
/// unit-testable without pumping the page). Pure functions only — the page
/// owns the source lists and calls [mergeFoodResults] on every build.

/// Where a search hit came from. Drives both ranking (see [foodResultScore])
/// and the page's enrich/attribution behavior.
enum FoodResultOrigin { local, backend, off, fatsecret }

class FoodResult {
  const FoodResult({required this.item, required this.origin});

  final FoodItem item;
  final FoodResultOrigin origin;
}

/// A food's identity for de-duplicating hits across sources and for matching
/// staged items back to results. Page-lifetime only — never persisted.
///
/// Barcode first: it's the one id every source agrees on. Catalog identity
/// (source, external_id) outranks backendId: a live FatSecret result carries
/// no backendId while the typeahead/local copy of the same ingested food does,
/// so keying the latter by backendId would show the food twice and let both
/// be staged. Source-qualified to keep FatSecret's externalId space apart from
/// custom foods' UUID space.
String? foodResultKey(FoodItem item) {
  if (item.barcode != null && item.barcode!.isNotEmpty) {
    return 'barcode:${item.barcode}';
  }
  if (item.externalId.isNotEmpty) {
    return 'external:${item.source}:${item.externalId}';
  }
  if (item.backendId != null) return 'backend:${item.backendId}';
  return null;
}

/// OFF search returns many low-quality duplicates of popular foods, some with
/// miscoded calories (e.g. a Big Mac stored as 540 kcal/100g). OFF's own
/// `completeness` score tracks this well, so hits below this floor are dropped
/// — but never all of them (see [offResultsForDisplay]).
const double kOffCompletenessFloor = 0.5;

/// The OFF hits worth showing: those at or above [kOffCompletenessFloor], or
/// every hit when none clear it, so an obscure (only) match still shows.
List<FoodItem> offResultsForDisplay(List<FoodItem> offResults) {
  final good = offResults
      .where((item) => (item.completeness ?? 0) >= kOffCompletenessFloor)
      .toList();
  return good.isNotEmpty ? good : offResults;
}

/// Name relevance of [name] for an already-lowercased query: exact beats
/// prefix beats word-start beats substring, and shorter names win ties.
int nameMatchScore(String name, String queryLower) {
  if (queryLower.isEmpty) return 0;
  final nameLower = name.toLowerCase();
  var score = 0;
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

/// Overall rank of one hit: name relevance, a small per-source nudge, and a
/// completeness tie-breaker.
int foodResultScore(FoodResult result, String queryLower) {
  var score = nameMatchScore(result.item.name, queryLower);
  score += switch (result.origin) {
    FoodResultOrigin.off => 5,
    // Between OFF's +5 and backend's +3, with no completeness bonus below
    // (FatSecret has no completeness field) — keeps OFF's best-filled
    // duplicates competitive while restaurant hits still rank by name match.
    FoodResultOrigin.fatsecret => 4,
    FoodResultOrigin.backend => 3,
    FoodResultOrigin.local => 1,
  };
  // Break ties toward higher-quality OFF entries so the best-filled duplicate
  // (correct calories) surfaces above sparser ones. Capped below the
  // name-match gradations so relevance still dominates.
  score += ((result.item.completeness ?? 0) * 50).round();
  return score;
}

/// Merges the four sources into the list the page renders.
///
/// An empty [query] shows the local list (recents/favorites) as-is. Otherwise
/// hits are de-duplicated by [foodResultKey] in source priority order (local,
/// backend, OFF, FatSecret — the first copy of a food wins) and ranked by
/// [foodResultScore]. Globals shadowed by one of the user's overrides are
/// hidden either way: the override row (a custom food, present in local or
/// backend results) stands in for them.
List<FoodResult> mergeFoodResults({
  required String query,
  required List<FoodItem> local,
  required List<FoodItem> backend,
  required List<FoodItem> off,
  required List<FoodItem> fatsecret,
}) {
  final trimmed = query.trim();
  final results = <FoodResult>[];
  final seenKeys = <String>{};

  // OFF rows carry no backend id, so barcodes are matched for those.
  final overriddenIds = <int>{};
  final overriddenBarcodes = <String>{};
  for (final item in [...local, ...backend]) {
    if (!item.isOverride) continue;
    overriddenIds.add(item.overridesBackendId!);
    final barcode = item.overridesBarcode;
    if (barcode != null && barcode.isNotEmpty) {
      overriddenBarcodes.add(barcode);
    }
  }
  bool shadowed(FoodItem item) =>
      !item.isCustom &&
      ((item.backendId != null && overriddenIds.contains(item.backendId)) ||
          (item.barcode != null && overriddenBarcodes.contains(item.barcode)));

  void addItems(List<FoodItem> items, FoodResultOrigin origin) {
    for (final item in items) {
      if (shadowed(item)) continue;
      final key = foodResultKey(item);
      if (key == null || !seenKeys.add(key)) continue;
      results.add(FoodResult(item: item, origin: origin));
    }
  }

  addItems(local, FoodResultOrigin.local);
  if (trimmed.isEmpty) {
    return results;
  }
  addItems(backend, FoodResultOrigin.backend);
  addItems(offResultsForDisplay(off), FoodResultOrigin.off);
  // No completeness floor here — FatSecret carries no completeness field.
  addItems(fatsecret, FoodResultOrigin.fatsecret);

  final queryLower = trimmed.toLowerCase();
  results.sort((a, b) {
    final scoreA = foodResultScore(a, queryLower);
    final scoreB = foodResultScore(b, queryLower);
    if (scoreA != scoreB) return scoreB.compareTo(scoreA);
    final lengthCompare = a.item.name.length.compareTo(b.item.name.length);
    if (lengthCompare != 0) return lengthCompare;
    return a.item.name.compareTo(b.item.name);
  });
  return results;
}
