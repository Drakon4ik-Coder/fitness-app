import 'food_models.dart';
import 'nutrition_api_service.dart';

/// Which section a nutrient is shown under on the detail page. Order here is the
/// order sections render in.
enum NutrientGroup { macros, vitamins, minerals, other }

extension NutrientGroupLabel on NutrientGroup {
  String get label {
    switch (this) {
      case NutrientGroup.macros:
        return 'Macros';
      case NutrientGroup.vitamins:
        return 'Vitamins';
      case NutrientGroup.minerals:
        return 'Minerals';
      case NutrientGroup.other:
        return 'Other';
    }
  }
}

/// One entry in the curated nutrient catalog. [offKey] is the Open Food Facts
/// nutriment id without the `_100g` suffix (e.g. `vitamin-c`); the raw blob
/// stores the value under `<offKey>_100g` and its unit under `<offKey>_unit`.
///
/// [unit] is the canonical unit we display and in which [dailyTarget] is
/// expressed. [overIsBad] flags nutrients where exceeding the target is a
/// cautionary state (sodium, sugars, saturated fat) rather than a goal to hit.
class NutrientSpec {
  const NutrientSpec({
    required this.key,
    required this.offKey,
    required this.label,
    required this.unit,
    required this.group,
    required this.dailyTarget,
    this.overIsBad = false,
    this.completenessTracked = false,
  });

  final String key;
  final String offKey;
  final String label;
  final String unit;
  final NutrientGroup group;
  final double dailyTarget;
  final bool overIsBad;

  /// Whether a per-day gap is worth flagging as "incomplete": true for the
  /// macros/core nutrients every food is expected to report, false for
  /// micronutrients where "missing" is normal (flagging would be noise).
  final bool completenessTracked;
}

/// Curated set of nutrients we surface. Trimmed to what OFF actually carries so
/// the detail page isn't a wall of permanent "no data" rows. Targets are generic
/// adult reference daily values; personalization comes later (Phase 3).
const List<NutrientSpec> kNutrientCatalog = [
  // Macros
  NutrientSpec(
    key: 'protein',
    offKey: 'proteins',
    label: 'Protein',
    unit: 'g',
    group: NutrientGroup.macros,
    dailyTarget: 50,
    completenessTracked: true,
  ),
  NutrientSpec(
    key: 'carbs',
    offKey: 'carbohydrates',
    label: 'Carbs',
    unit: 'g',
    group: NutrientGroup.macros,
    dailyTarget: 260,
    completenessTracked: true,
  ),
  NutrientSpec(
    key: 'sugars',
    offKey: 'sugars',
    label: 'Sugars',
    unit: 'g',
    group: NutrientGroup.macros,
    dailyTarget: 90,
    overIsBad: true,
    completenessTracked: true,
  ),
  NutrientSpec(
    key: 'fat',
    offKey: 'fat',
    label: 'Fat',
    unit: 'g',
    group: NutrientGroup.macros,
    dailyTarget: 70,
    completenessTracked: true,
  ),
  NutrientSpec(
    key: 'saturated_fat',
    offKey: 'saturated-fat',
    label: 'Saturated fat',
    unit: 'g',
    group: NutrientGroup.macros,
    dailyTarget: 20,
    overIsBad: true,
    completenessTracked: true,
  ),
  NutrientSpec(
    key: 'fiber',
    offKey: 'fiber',
    label: 'Fiber',
    unit: 'g',
    group: NutrientGroup.macros,
    dailyTarget: 30,
    completenessTracked: true,
  ),
  // Vitamins
  NutrientSpec(
    key: 'vitamin_a',
    offKey: 'vitamin-a',
    label: 'Vitamin A',
    unit: 'µg',
    group: NutrientGroup.vitamins,
    dailyTarget: 900,
  ),
  NutrientSpec(
    key: 'vitamin_c',
    offKey: 'vitamin-c',
    label: 'Vitamin C',
    unit: 'mg',
    group: NutrientGroup.vitamins,
    dailyTarget: 80,
  ),
  NutrientSpec(
    key: 'vitamin_d',
    offKey: 'vitamin-d',
    label: 'Vitamin D',
    unit: 'µg',
    group: NutrientGroup.vitamins,
    dailyTarget: 20,
  ),
  NutrientSpec(
    key: 'vitamin_e',
    offKey: 'vitamin-e',
    label: 'Vitamin E',
    unit: 'mg',
    group: NutrientGroup.vitamins,
    dailyTarget: 15,
  ),
  NutrientSpec(
    key: 'vitamin_b6',
    offKey: 'vitamin-b6',
    label: 'Vitamin B6',
    unit: 'mg',
    group: NutrientGroup.vitamins,
    dailyTarget: 1.3,
  ),
  NutrientSpec(
    key: 'folate',
    offKey: 'vitamin-b9',
    label: 'Folate (B9)',
    unit: 'µg',
    group: NutrientGroup.vitamins,
    dailyTarget: 400,
  ),
  NutrientSpec(
    key: 'vitamin_b12',
    offKey: 'vitamin-b12',
    label: 'Vitamin B12',
    unit: 'µg',
    group: NutrientGroup.vitamins,
    dailyTarget: 2.4,
  ),
  // Minerals
  NutrientSpec(
    key: 'sodium',
    offKey: 'sodium',
    label: 'Sodium',
    unit: 'mg',
    group: NutrientGroup.minerals,
    dailyTarget: 2300,
    overIsBad: true,
  ),
  NutrientSpec(
    key: 'salt',
    offKey: 'salt',
    label: 'Salt',
    unit: 'g',
    group: NutrientGroup.minerals,
    dailyTarget: 6,
    overIsBad: true,
    completenessTracked: true,
  ),
  NutrientSpec(
    key: 'calcium',
    offKey: 'calcium',
    label: 'Calcium',
    unit: 'mg',
    group: NutrientGroup.minerals,
    dailyTarget: 1000,
  ),
  NutrientSpec(
    key: 'iron',
    offKey: 'iron',
    label: 'Iron',
    unit: 'mg',
    group: NutrientGroup.minerals,
    dailyTarget: 18,
  ),
  NutrientSpec(
    key: 'potassium',
    offKey: 'potassium',
    label: 'Potassium',
    unit: 'mg',
    group: NutrientGroup.minerals,
    dailyTarget: 3500,
  ),
  NutrientSpec(
    key: 'magnesium',
    offKey: 'magnesium',
    label: 'Magnesium',
    unit: 'mg',
    group: NutrientGroup.minerals,
    dailyTarget: 400,
  ),
  NutrientSpec(
    key: 'zinc',
    offKey: 'zinc',
    label: 'Zinc',
    unit: 'mg',
    group: NutrientGroup.minerals,
    dailyTarget: 11,
  ),
  // Other
  NutrientSpec(
    key: 'cholesterol',
    offKey: 'cholesterol',
    label: 'Cholesterol',
    unit: 'mg',
    group: NutrientGroup.other,
    dailyTarget: 300,
    overIsBad: true,
  ),
];

/// Grams that one of [unit] represents. Used to move between the raw OFF value
/// (in its own `_unit`) and the catalog's canonical unit.
double? _gramsPerUnit(String? unit) {
  switch ((unit ?? '').toLowerCase()) {
    case 'g':
      return 1.0;
    case 'mg':
      return 1e-3;
    case 'µg': // micro sign U+00B5
    case 'μg': // greek small mu U+03BC
    case 'ug':
    case 'mcg':
      return 1e-6;
    case 'kg':
      return 1e3;
    default:
      // Unknown or non-mass units (e.g. IU) can't be converted safely; treat as
      // missing rather than render a wrong number.
      return null;
  }
}

/// Reads a single nutrient's per-100g value from an OFF nutriments blob and
/// returns it converted into [spec.unit]. `null` when the nutrient is absent or
/// carries a unit we can't convert. OFF stores `<offKey>_100g` in the unit given
/// by `<offKey>_unit`; when the unit is missing we assume grams (its default for
/// the standardized fields).
double? nutrientPer100g(NutrientSpec spec, Map<String, dynamic>? nutriments) {
  if (nutriments == null) return null;
  final raw = parseNullableDouble(nutriments['${spec.offKey}_100g']);
  if (raw == null) return null;
  final sourceUnit = nutriments['${spec.offKey}_unit'];
  final fromGrams = _gramsPerUnit(sourceUnit is String ? sourceUnit : 'g');
  final toGrams = _gramsPerUnit(spec.unit);
  if (fromGrams == null || toGrams == null) return null;
  return raw * fromGrams / toGrams;
}

/// A day-total amount for one nutrient. [amount] is in [spec.unit]; `null` means
/// no logged food carried data for it.
class NutrientTotal {
  const NutrientTotal({
    required this.spec,
    required this.amount,
    this.reportedCount = 0,
    this.totalCount = 0,
  });

  final NutrientSpec spec;
  final double? amount;

  /// How many of the aggregated foods reported this nutrient, and how many were
  /// aggregated in total. For a single food these are 0/1 or 1/1; for a day they
  /// span every logged entry. Drives the "incomplete" (floor) treatment.
  final int reportedCount;
  final int totalCount;

  bool get hasData => amount != null;

  /// The shown value is a floor: some — but not all — aggregated foods reported
  /// this nutrient, and it's one we expect every food to have (macros/core). The
  /// user can fill the gaps in themselves (KAN-19).
  bool get isIncomplete =>
      spec.completenessTracked &&
      amount != null &&
      totalCount > reportedCount &&
      reportedCount > 0;

  /// Fraction of the daily target in [0, 1], clamped. Zero when there's no data.
  double get progress {
    final value = amount;
    if (value == null || spec.dailyTarget <= 0) return 0;
    final ratio = value / spec.dailyTarget;
    return ratio.clamp(0.0, 1.0).toDouble();
  }

  /// Whether the amount exceeds the target for a nutrient where that's a
  /// cautionary state (sodium, sugars, etc.).
  bool get isOverLimit =>
      spec.overIsBad && amount != null && amount! > spec.dailyTarget;
}

/// Builds the catalog-aligned totals from the server's per-day `nutrients` map
/// (`{key: {amount, unit, group}}`). The server normalizes to the same canonical
/// units as [kNutrientCatalog], so amounts are used directly; keys the server
/// omits (no data that day) become `null` totals. Preferred over
/// [aggregateNutrients] when the day payload carries a server breakdown.
List<NutrientTotal> nutrientTotalsFromServer(Map<String, dynamic> nutrients) {
  return [
    for (final spec in kNutrientCatalog)
      () {
        final raw = nutrients[spec.key];
        if (raw is! Map) {
          return NutrientTotal(spec: spec, amount: null);
        }
        final amount = parseNullableDouble(raw['amount']);
        // Older payloads omit reported/total; default to "complete" (reported ==
        // total) so they never render as incomplete.
        final total = (raw['total'] as num?)?.toInt() ?? (amount != null ? 1 : 0);
        final reported =
            (raw['reported'] as num?)?.toInt() ?? (amount != null ? total : 0);
        return NutrientTotal(
          spec: spec,
          amount: amount,
          reportedCount: reported,
          totalCount: total,
        );
      }(),
  ];
}

/// Catalog-aligned totals for a single food at a given [grams] amount, read from
/// its stored OFF nutriments blob. Powers the "check the nutrition before adding"
/// preview in the amount sheet. Nutrients the food lacks become `null` totals.
List<NutrientTotal> nutrientTotalsForItem(FoodItem item, double grams) {
  final nutriments = item.nutrimentsJson;
  final factor = grams / 100.0;
  return [
    for (final spec in kNutrientCatalog)
      () {
        final per100 = nutrientPer100g(spec, nutriments);
        final has = per100 != null;
        return NutrientTotal(
          spec: spec,
          amount: has ? per100 * factor : null,
          reportedCount: has ? 1 : 0,
          totalCount: 1,
        );
      }(),
  ];
}

/// Aggregates every catalog nutrient across a day's logged entries, scaling each
/// food's per-100g value by the logged quantity. A nutrient only counts entries
/// that actually carry data for it; if none do, its total is `null` ("no data").
List<NutrientTotal> aggregateNutrients(Iterable<NutritionEntry> entries) {
  final sums = <String, double>{};
  // Foods that reported each nutrient. A food with no blob at all still counts
  // toward the denominator (its macros are unknown -> the day total is a floor).
  final reported = <String, int>{};
  var entryCount = 0;
  for (final entry in entries) {
    entryCount++;
    final nutriments = entry.foodItem.nutrimentsJson;
    if (nutriments == null) continue;
    final factor = entry.quantityG / 100.0;
    for (final spec in kNutrientCatalog) {
      final per100 = nutrientPer100g(spec, nutriments);
      if (per100 == null) continue;
      sums[spec.key] = (sums[spec.key] ?? 0) + per100 * factor;
      reported[spec.key] = (reported[spec.key] ?? 0) + 1;
    }
  }
  return [
    for (final spec in kNutrientCatalog)
      NutrientTotal(
        spec: spec,
        amount: reported.containsKey(spec.key) ? sums[spec.key] : null,
        reportedCount: reported[spec.key] ?? 0,
        totalCount: entryCount,
      ),
  ];
}
