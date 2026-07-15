import 'dart:convert';

import 'food_models.dart';

// Measurement-description heads that name a mass/volume rather than a
// countable piece — a serving labelled "100 g" or "355 ml" carries no piece
// identity, unlike "burger" or "slice". Matched against the normalized head
// (see _measurementHead), so FatSecret's qualified forms ("oz, with bone,
// cooked", "serving (98 g)") are caught by their leading unit word.
const Set<String> _bareMassOrVolumeWords = {
  'g',
  'gram',
  'grams',
  'kg',
  'mg',
  'ml',
  'l',
  'fl oz',
  'oz',
  'lb',
  'cup',
  'cups',
  'tbsp',
  'tsp',
  'serving',
  'servings',
};

/// Maps FatSecret's `foods.search` / `food.get.v4` JSON (passed through
/// verbatim by the backend proxy, KAN-67) into [FoodItem]s. Mirrors
/// [OffMapper]'s role for the OFF source: no HTTP here, just shape
/// translation, so it's directly unit-testable against canned payloads.
class FatSecretMapper {
  /// A `foods.search` hit. FatSecret's search never returns serving data —
  /// only `food_description`, a free-text summary whose basis varies ("Per
  /// 100g", "Per 1 burger", "Per 1 serving"). Macros are only trustworthy
  /// when that basis is per-100g; any other basis leaves them null so the
  /// page's lazy enrich-on-tap (a `food.get.v4` fetch) fills them in, exactly
  /// like an OFF barcode-less result.
  FoodItem? mapSummary(Map<String, dynamic> food) {
    final externalId = food['food_id']?.toString().trim();
    if (externalId == null || externalId.isEmpty) return null;
    final name = (food['food_name'] as String?)?.trim() ?? '';
    final brands = (food['brand_name'] as String?)?.trim() ?? '';
    final description = (food['food_description'] as String?) ?? '';

    double? kcal100g;
    double? protein;
    double? carbs;
    double? fat;
    Map<String, dynamic>? nutrimentsJson;
    if (_isPer100gBasis(description)) {
      kcal100g = _extractDescriptionValue(description, 'Calories');
      fat = _extractDescriptionValue(description, 'Fat');
      carbs = _extractDescriptionValue(description, 'Carbs');
      protein = _extractDescriptionValue(description, 'Protein');
      nutrimentsJson = {
        if (kcal100g != null) 'energy-kcal_100g': kcal100g,
        if (fat != null) 'fat_100g': fat,
        if (carbs != null) 'carbohydrates_100g': carbs,
        if (protein != null) 'proteins_100g': protein,
      };
      // Same normalization as mapDetail: a per-100g description whose values
      // all fail to parse must yield null, not {} — the page's no-nutrition
      // staging guard keys on nutrimentsJson == null, and an empty map would
      // let a zero-calorie phantom through when enrich also comes up empty.
      if (nutrimentsJson.isEmpty) nutrimentsJson = null;
    }

    final contentHash = buildFoodContentHash(
      source: fatsecretSource,
      externalId: externalId,
      name: name,
      brands: brands,
      kcal100g: kcal100g,
      protein: protein,
      carbs: carbs,
      fat: fat,
      sugars: null,
      fiber: null,
      salt: null,
      servingSizeG: null,
      imageSignature: null,
    );

    return FoodItem(
      source: fatsecretSource,
      externalId: externalId,
      barcode: null,
      name: name,
      brands: brands,
      imageUrl: null,
      contentHash: contentHash,
      kcal100g: kcal100g,
      proteinG100g: protein,
      carbsG100g: carbs,
      fatG100g: fat,
      completeness: null,
      rawSourceJson: jsonEncode({'food': food}),
      nutrimentsJson: nutrimentsJson,
    );
  }

  /// A `food.get.v4` detail. Every serving's nutrition is for the WHOLE
  /// described portion, not per 100 g, so a serving with a known metric mass
  /// (g/ml) is picked to normalize against and everything is rescaled to
  /// per-100g here. When no serving carries a usable metric mass, this
  /// returns null rather than inventing a weight — the page falls back to
  /// the un-enriched summary (see add_food_page's `_enrich`).
  FoodItem? mapDetail(Map<String, dynamic> food) {
    final externalId = food['food_id']?.toString().trim();
    if (externalId == null || externalId.isEmpty) return null;
    final name = (food['food_name'] as String?)?.trim() ?? '';
    final brands = (food['brand_name'] as String?)?.trim() ?? '';

    final servingsWrapper = food['servings'];
    final servings = servingsWrapper is Map
        ? _asMapList(servingsWrapper['serving'])
        : const <Map<String, dynamic>>[];
    if (servings.isEmpty) return null;

    final normServing = _pickNormalizationServing(servings);
    if (normServing == null) return null;
    final metricAmount = parseNullableDouble(
      normServing['metric_serving_amount'],
    )!;
    final factor = 100.0 / metricAmount;

    double? scaled(String key, {double divisor = 1}) {
      final raw = parseNullableDouble(normServing[key]);
      if (raw == null) return null;
      return raw * factor / divisor;
    }

    // Macro/energy fields are already grams (or kcal); the mg/µg nutrients
    // divide down to grams so every stored value shares one unit and the
    // catalog's `_unit`-less read-back (grams by default) stays exact.
    final kcal100g = scaled('calories');
    final protein = scaled('protein');
    final carbs = scaled('carbohydrate');
    final fat = scaled('fat');
    final saturatedFat = scaled('saturated_fat');
    final sugars = scaled('sugar');
    final fiber = scaled('fiber');
    final sodium = scaled('sodium', divisor: 1000);
    final potassium = scaled('potassium', divisor: 1000);
    final cholesterol = scaled('cholesterol', divisor: 1000);
    final calcium = scaled('calcium', divisor: 1000);
    final iron = scaled('iron', divisor: 1000);
    final vitaminC = scaled('vitamin_c', divisor: 1000);
    final vitaminA = scaled('vitamin_a', divisor: 1e6);
    final vitaminD = scaled('vitamin_d', divisor: 1e6);
    // OFF convention: salt = sodium * 2.5, same (grams) basis as sodium here.
    final salt = sodium == null ? null : sodium * 2.5;

    final nutrimentsJson = <String, dynamic>{
      if (kcal100g != null) 'energy-kcal_100g': kcal100g,
      if (protein != null) 'proteins_100g': protein,
      if (carbs != null) 'carbohydrates_100g': carbs,
      if (fat != null) 'fat_100g': fat,
      if (saturatedFat != null) 'saturated-fat_100g': saturatedFat,
      if (sugars != null) 'sugars_100g': sugars,
      if (fiber != null) 'fiber_100g': fiber,
      if (sodium != null) 'sodium_100g': sodium,
      if (potassium != null) 'potassium_100g': potassium,
      if (cholesterol != null) 'cholesterol_100g': cholesterol,
      if (calcium != null) 'calcium_100g': calcium,
      if (iron != null) 'iron_100g': iron,
      if (vitaminC != null) 'vitamin-c_100g': vitaminC,
      if (vitaminA != null) 'vitamin-a_100g': vitaminA,
      if (vitaminD != null) 'vitamin-d_100g': vitaminD,
      if (salt != null) 'salt_100g': salt,
    };

    // A piece serving (e.g. "1 burger") is the payoff for restaurant items:
    // it lets the page default to a whole item instead of a raw 100 g.
    // Preferred over the normalization serving for the default weight, since
    // that serving may be the generic "100 g" row rather than the natural
    // portion.
    final pieceServing = _pickPieceServing(servings);
    double? gramsPerPiece;
    String? pieceUnit;
    double servingSizeG;
    String? syntheticServingText;
    if (pieceServing != null) {
      final pieceMetric = parseNullableDouble(
        pieceServing['metric_serving_amount'],
      )!;
      final numberOfUnits =
          parseNullableDouble(pieceServing['number_of_units']) ?? 1.0;
      final units = numberOfUnits > 0 ? numberOfUnits : 1.0;
      gramsPerPiece = pieceMetric / units;
      pieceUnit = _cleanMeasurementLabel(
        pieceServing['measurement_description'],
      );
      servingSizeG = pieceMetric;
      // The backend has no piece columns; fromBackendDetail re-derives pieces
      // solely from an OFF-style `serving_size` text in the raw blob. Without
      // this synthetic text the piece default would survive exactly until the
      // first ingest and vanish on every later reload (other devices, food
      // refresh). `food` itself stays verbatim.
      if (pieceUnit != null) {
        syntheticServingText =
            '${_compactNumber(units)} $pieceUnit '
            '(${_compactNumber(pieceMetric)} g)';
      }
    } else {
      servingSizeG = metricAmount;
    }

    final contentHash = buildFoodContentHash(
      source: fatsecretSource,
      externalId: externalId,
      name: name,
      brands: brands,
      kcal100g: kcal100g,
      protein: protein,
      carbs: carbs,
      fat: fat,
      sugars: sugars,
      fiber: fiber,
      salt: salt,
      servingSizeG: servingSizeG,
      imageSignature: null,
    );

    return FoodItem(
      source: fatsecretSource,
      externalId: externalId,
      barcode: null,
      name: name,
      brands: brands,
      imageUrl: null,
      contentHash: contentHash,
      kcal100g: kcal100g,
      proteinG100g: protein,
      carbsG100g: carbs,
      fatG100g: fat,
      sugarsG100g: sugars,
      fiberG100g: fiber,
      saltG100g: salt,
      servingSizeG: servingSizeG,
      gramsPerPiece: gramsPerPiece,
      pieceUnit: pieceUnit,
      completeness: null,
      rawSourceJson: jsonEncode({
        'food': food,
        if (syntheticServingText != null) 'serving_size': syntheticServingText,
      }),
      nutrimentsJson: nutrimentsJson.isEmpty ? null : nutrimentsJson,
    );
  }

  bool _isPer100gBasis(String description) {
    return RegExp(
      r'^\s*per\s+100\s*g\b',
      caseSensitive: false,
    ).hasMatch(description);
  }

  double? _extractDescriptionValue(String description, String label) {
    final match = RegExp(
      '$label:\\s*([\\d.]+)',
      caseSensitive: false,
    ).firstMatch(description);
    if (match == null) return null;
    return double.tryParse(match.group(1)!);
  }

  /// The serving to normalize every other value against: prefers an explicit
  /// "100 g"/"100g" serving with a real metric mass, else the first serving
  /// that carries any usable metric mass at all.
  Map<String, dynamic>? _pickNormalizationServing(
    List<Map<String, dynamic>> servings,
  ) {
    bool isPer100(Map<String, dynamic> serving) {
      final desc =
          (serving['serving_description'] as String?)?.trim().toLowerCase() ??
          '';
      return RegExp(r'^100\s*g$').hasMatch(desc);
    }

    for (final serving in servings) {
      if (_hasMetricMass(serving) && isPer100(serving)) return serving;
    }
    for (final serving in servings) {
      if (_hasMetricMass(serving)) return serving;
    }
    return null;
  }

  /// The serving that names a countable piece (e.g. "1 burger"), if any.
  /// Pieceness is decided on the normalized head only: "oz, with bone,
  /// cooked" is still a mass, and "slice, large" is still a slice.
  Map<String, dynamic>? _pickPieceServing(List<Map<String, dynamic>> servings) {
    for (final serving in servings) {
      final head = _measurementHead(serving['measurement_description']);
      if (head == null) continue;
      if (_bareMassOrVolumeWords.contains(head)) continue;
      if (_hasMetricMass(serving)) return serving;
    }
    return null;
  }

  bool _hasMetricMass(Map<String, dynamic> serving) {
    final unit = (serving['metric_serving_unit'] as String?)
        ?.trim()
        .toLowerCase();
    final amount = parseNullableDouble(serving['metric_serving_amount']);
    return (unit == 'g' || unit == 'ml') && amount != null && amount > 0;
  }

  /// "219" for whole numbers, "28.35" otherwise — keeps the synthetic
  /// serving text natural ("1 burger (219 g)", not "219.0 g").
  String _compactNumber(double value) {
    return value == value.roundToDouble()
        ? value.round().toString()
        : value.toString();
  }

  /// Normalized head of a measurement description: lower-cased, cut before
  /// any comma or parenthetical qualifier, leading count stripped ("3.5 oz
  /// (100 g)" -> "oz", "slice, large" -> "slice"). FatSecret qualifies units
  /// freely, so only the head carries the piece-vs-mass identity — and only
  /// the head is fit to show as a unit label.
  String? _measurementHead(dynamic value) {
    if (value is! String) return null;
    var head = value.trim().toLowerCase().split(RegExp(r'[,(]')).first.trim();
    head = head.replaceFirst(RegExp(r'^\d+(\.\d+)?\s*'), '');
    return head.isEmpty ? null : head;
  }

  /// Singular, lower-cased label for one piece ("burgers" -> "burger"),
  /// mirroring the singularization `parseLeadingPiece` applies to OFF's
  /// free-text servings. Qualifiers are dropped with the rest of the tail —
  /// the amount sheet pluralizes this label, so it must be a clean noun.
  String? _cleanMeasurementLabel(dynamic value) {
    var label = _measurementHead(value);
    if (label == null) return null;
    if (label.length > 3 && label.endsWith('s')) {
      label = label.substring(0, label.length - 1);
    }
    return label.isEmpty ? null : label;
  }

  /// FatSecret returns a single object (not a one-element list) when a list
  /// field has exactly one entry.
  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is List) {
      return value.whereType<Map<String, dynamic>>().toList();
    }
    if (value is Map) return [value.cast<String, dynamic>()];
    return const [];
  }
}
