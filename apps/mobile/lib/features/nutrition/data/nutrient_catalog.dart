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
/// expressed. [overIsBad] flags restrict-type nutrients (sodium, sugars,
/// saturated fat): exceeding their target never celebrates, and they're the
/// suggested defaults for the opt-in over-goal warnings (KAN-38) — it does not
/// force a warning by itself.
class NutrientSpec {
  const NutrientSpec({
    required this.key,
    required this.offKey,
    required this.label,
    required this.unit,
    required this.group,
    required this.dailyTarget,
    this.shortLabel,
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

  /// Compact label for tight surfaces (the amount-sheet pills): "P", "Vit C",
  /// "Na". Falls back to [label] via [pillLabel] when unset.
  final String? shortLabel;

  String get pillLabel => shortLabel ?? label;

  /// Whether a per-day gap is worth flagging as "incomplete": true for the
  /// macros/core nutrients every food is expected to report, false for
  /// micronutrients where "missing" is normal (flagging would be noise).
  final bool completenessTracked;

  /// A copy with [dailyTarget] replaced. Used to layer the user's personalized
  /// goals over the reference defaults ([resolveCatalog]) without touching any
  /// other field.
  NutrientSpec copyWith({double? dailyTarget}) => NutrientSpec(
    key: key,
    offKey: offKey,
    label: label,
    unit: unit,
    group: group,
    dailyTarget: dailyTarget ?? this.dailyTarget,
    shortLabel: shortLabel,
    overIsBad: overIsBad,
    completenessTracked: completenessTracked,
  );
}

/// The catalog with the user's per-nutrient [goals] (keyed by [NutrientSpec.key],
/// in each nutrient's canonical unit) layered over the reference defaults. Keys
/// absent from [goals], and non-positive values, keep the catalog default — so a
/// single resolved catalog is the one source of truth every page reads. Returns
/// [kNutrientCatalog] unchanged when [goals] is null or empty.
List<NutrientSpec> resolveCatalog(
  Map<String, double>? goals, {
  List<NutrientSpec> base = kNutrientCatalog,
}) {
  if (goals == null || goals.isEmpty) return base;
  return [
    for (final spec in base)
      () {
        final override = goals[spec.key];
        return (override != null && override > 0)
            ? spec.copyWith(dailyTarget: override)
            : spec;
      }(),
  ];
}

/// How an exceeded goal reads on any surface (KAN-38): amber warning only when
/// the user opted the nutrient in; hitting a target-type goal (protein, fiber,
/// vitamins, minerals) is a win; overshooting a restrict-type nutrient the user
/// hasn't opted into warning for is neutral information, not a nag.
enum OverGoalTreatment { warn, celebrate, neutral }

/// Resolves the over-goal treatment for [spec] against the user's opt-in
/// [warnNutrients] set (from `UserPreferences.warnNutrients`). Which nutrients
/// deserve a warning is a personal-goal question, so nothing warns by default —
/// [kSuggestedWarnNutrients] is only the settings page's suggestion.
OverGoalTreatment overGoalTreatment(
  NutrientSpec spec,
  Set<String> warnNutrients,
) {
  if (warnNutrients.contains(spec.key)) return OverGoalTreatment.warn;
  // Restrict-type nutrients plus the energy macros: exceeding these is not a
  // goal met, but it only warns when the user asked it to.
  if (spec.overIsBad || spec.key == 'carbs' || spec.key == 'fat') {
    return OverGoalTreatment.neutral;
  }
  return OverGoalTreatment.celebrate;
}

/// The catalog's cautionary nutrients, offered as pre-suggested (but unchecked
/// by default) warning toggles in settings.
List<String> get kSuggestedWarnNutrients => [
  for (final spec in kNutrientCatalog)
    if (spec.overIsBad) spec.key,
];

/// Default daily energy budget used until the user sets [UserPreferences.calorieGoal].
const int kDefaultCalorieGoal = 2200;

/// The nutrients highlighted on the today page until the user picks their own.
const List<String> kDefaultFocusNutrients = ['protein', 'carbs', 'fat'];

/// Upper bound on how many nutrients the today page can highlight at once.
const int kMaxFocusNutrients = 4;

/// The specs for the user's focus [keys], in the user's order. Keys that don't
/// exist in [base] are dropped (a stale selection never crashes the dashboard);
/// a null/empty/all-invalid selection falls back to [kDefaultFocusNutrients].
List<NutrientSpec> resolveFocusSpecs(
  List<String>? keys, {
  List<NutrientSpec> base = kNutrientCatalog,
}) {
  final byKey = {for (final spec in base) spec.key: spec};
  final resolved = <NutrientSpec>[
    for (final key in keys ?? const <String>[])
      if (byKey.containsKey(key)) byKey[key]!,
  ];
  if (resolved.isNotEmpty) return resolved.take(kMaxFocusNutrients).toList();
  return [
    for (final key in kDefaultFocusNutrients)
      if (byKey.containsKey(key)) byKey[key]!,
  ];
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
    shortLabel: 'P',
    unit: 'g',
    group: NutrientGroup.macros,
    // Higher than the 50 g generic RDA: this is a fitness app, and 150 g is the
    // long-standing default the today page has always shown. Users tune it on
    // the account page.
    dailyTarget: 150,
    completenessTracked: true,
  ),
  NutrientSpec(
    key: 'carbs',
    offKey: 'carbohydrates',
    label: 'Carbs',
    shortLabel: 'C',
    unit: 'g',
    group: NutrientGroup.macros,
    dailyTarget: 260,
    completenessTracked: true,
  ),
  NutrientSpec(
    key: 'sugars',
    offKey: 'sugars',
    label: 'Sugars',
    shortLabel: 'Sug',
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
    shortLabel: 'F',
    unit: 'g',
    group: NutrientGroup.macros,
    dailyTarget: 70,
    completenessTracked: true,
  ),
  NutrientSpec(
    key: 'saturated_fat',
    offKey: 'saturated-fat',
    label: 'Saturated fat',
    shortLabel: 'SatF',
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
    shortLabel: 'Fib',
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
    shortLabel: 'Vit A',
    unit: 'µg',
    group: NutrientGroup.vitamins,
    dailyTarget: 900,
  ),
  NutrientSpec(
    key: 'vitamin_c',
    offKey: 'vitamin-c',
    label: 'Vitamin C',
    shortLabel: 'Vit C',
    unit: 'mg',
    group: NutrientGroup.vitamins,
    dailyTarget: 80,
  ),
  NutrientSpec(
    key: 'vitamin_d',
    offKey: 'vitamin-d',
    label: 'Vitamin D',
    shortLabel: 'Vit D',
    unit: 'µg',
    group: NutrientGroup.vitamins,
    dailyTarget: 20,
  ),
  NutrientSpec(
    key: 'vitamin_e',
    offKey: 'vitamin-e',
    label: 'Vitamin E',
    shortLabel: 'Vit E',
    unit: 'mg',
    group: NutrientGroup.vitamins,
    dailyTarget: 15,
  ),
  NutrientSpec(
    key: 'vitamin_b6',
    offKey: 'vitamin-b6',
    label: 'Vitamin B6',
    shortLabel: 'B6',
    unit: 'mg',
    group: NutrientGroup.vitamins,
    dailyTarget: 1.3,
  ),
  NutrientSpec(
    key: 'folate',
    offKey: 'vitamin-b9',
    label: 'Folate (B9)',
    shortLabel: 'B9',
    unit: 'µg',
    group: NutrientGroup.vitamins,
    dailyTarget: 400,
  ),
  NutrientSpec(
    key: 'vitamin_b12',
    offKey: 'vitamin-b12',
    label: 'Vitamin B12',
    shortLabel: 'B12',
    unit: 'µg',
    group: NutrientGroup.vitamins,
    dailyTarget: 2.4,
  ),
  // Minerals
  NutrientSpec(
    key: 'sodium',
    offKey: 'sodium',
    label: 'Sodium',
    shortLabel: 'Na',
    unit: 'mg',
    group: NutrientGroup.minerals,
    dailyTarget: 2300,
    overIsBad: true,
  ),
  NutrientSpec(
    key: 'salt',
    offKey: 'salt',
    label: 'Salt',
    shortLabel: 'Salt',
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
    shortLabel: 'Ca',
    unit: 'mg',
    group: NutrientGroup.minerals,
    dailyTarget: 1000,
  ),
  NutrientSpec(
    key: 'iron',
    offKey: 'iron',
    label: 'Iron',
    shortLabel: 'Fe',
    unit: 'mg',
    group: NutrientGroup.minerals,
    dailyTarget: 18,
  ),
  NutrientSpec(
    key: 'potassium',
    offKey: 'potassium',
    label: 'Potassium',
    shortLabel: 'K',
    unit: 'mg',
    group: NutrientGroup.minerals,
    dailyTarget: 3500,
  ),
  NutrientSpec(
    key: 'magnesium',
    offKey: 'magnesium',
    label: 'Magnesium',
    shortLabel: 'Mg',
    unit: 'mg',
    group: NutrientGroup.minerals,
    dailyTarget: 400,
  ),
  NutrientSpec(
    key: 'zinc',
    offKey: 'zinc',
    label: 'Zinc',
    shortLabel: 'Zn',
    unit: 'mg',
    group: NutrientGroup.minerals,
    dailyTarget: 11,
  ),
  // Other
  NutrientSpec(
    key: 'cholesterol',
    offKey: 'cholesterol',
    label: 'Cholesterol',
    shortLabel: 'Chol',
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

/// Per-100g value for [spec] from [item], in [spec.unit]. Prefers the stored
/// OFF nutriments blob; for the flat-column macros it falls back to the flat
/// per-100g columns, which older local rows carry even when no blob was saved.
/// Every per-item lookup (single-food totals, day aggregation, contributor
/// ranking) must go through here, not [nutrientPer100g], or blob-less foods
/// silently drop out of the totals.
double? nutrientPer100gForItem(NutrientSpec spec, FoodItem item) {
  final fromBlob = nutrientPer100g(spec, item.nutrimentsJson);
  if (fromBlob != null) return fromBlob;
  // All flat columns are stored in grams, matching these specs' catalog units.
  switch (spec.key) {
    case 'protein':
      return item.proteinG100g;
    case 'carbs':
      return item.carbsG100g;
    case 'fat':
      return item.fatG100g;
    case 'sugars':
      return item.sugarsG100g;
    case 'fiber':
      return item.fiberG100g;
    case 'salt':
      return item.saltG100g;
  }
  return null;
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

  /// Whether the amount exceeds the daily target. How that reads (warn /
  /// celebrate / neutral) is the user's call — see [overGoalTreatment].
  bool get isOverTarget => amount != null && amount! > spec.dailyTarget;
}

/// Builds the catalog-aligned totals from the server's per-day `nutrients` map
/// (`{key: {amount, unit, group}}`). The server normalizes to the same canonical
/// units as [kNutrientCatalog], so amounts are used directly; keys the server
/// omits (no data that day) become `null` totals. Preferred over
/// [aggregateNutrients] when the day payload carries a server breakdown.
List<NutrientTotal> nutrientTotalsFromServer(
  Map<String, dynamic> nutrients, {
  List<NutrientSpec> catalog = kNutrientCatalog,
}) {
  return [
    for (final spec in catalog)
      () {
        final raw = nutrients[spec.key];
        if (raw is! Map) {
          return NutrientTotal(spec: spec, amount: null);
        }
        final amount = parseNullableDouble(raw['amount']);
        // Older payloads omit reported/total; default to "complete" (reported ==
        // total) so they never render as incomplete.
        final total =
            (raw['total'] as num?)?.toInt() ?? (amount != null ? 1 : 0);
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

/// Catalog-aligned totals for a single food at a given [grams] amount. Powers
/// the "check the nutrition before adding" preview in the amount sheet.
/// Nutrients the food lacks become `null` totals.
List<NutrientTotal> nutrientTotalsForItem(
  FoodItem item,
  double grams, {
  List<NutrientSpec> catalog = kNutrientCatalog,
}) {
  final factor = grams / 100.0;
  return [
    for (final spec in catalog)
      () {
        final per100 = nutrientPer100gForItem(spec, item);
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

/// One logged food's share of a single nutrient's day total, in [spec.unit].
/// [amount] is that food scaled to its logged [quantityG]; [share] is the
/// fraction (0..1) of the day's contributor sum it accounts for.
class NutrientContribution {
  const NutrientContribution({
    required this.name,
    required this.brand,
    required this.amount,
    required this.quantityG,
    required this.share,
  });

  final String name;
  final String brand;
  final double amount;
  final double quantityG;
  final double share;
}

/// The day's contributions to a single nutrient: the ranked foods that carry it
/// plus how many logged entries had no data for it (for a "not everything
/// reports this" footnote).
class NutrientContributionBreakdown {
  const NutrientContributionBreakdown({
    required this.spec,
    required this.contributors,
    required this.total,
    required this.entryCount,
  });

  final NutrientSpec spec;

  /// Foods that carried the nutrient, ranked high→low. Excludes entries that
  /// reported nothing (or a literal 0 — they don't move the total).
  final List<NutrientContribution> contributors;

  /// Sum of every contributor's amount, in [spec.unit]. The denominator behind
  /// each [NutrientContribution.share].
  final double total;

  /// Total logged entries considered, whether or not they carried the nutrient.
  final int entryCount;

  /// Logged foods that had no usable data for this nutrient.
  int get missingCount => entryCount - contributors.length;
}

/// Ranks a day's logged foods by how much each contributes to [spec], scaling
/// every food's per-100g value by its logged quantity. Foods that don't report
/// the nutrient (or report a plain 0) are dropped — a "main contributor" list is
/// only about the foods that actually move the total. Sorted high→low.
NutrientContributionBreakdown nutrientContributors(
  Iterable<NutritionEntry> entries,
  NutrientSpec spec,
) {
  final contributors = <NutrientContribution>[];
  var total = 0.0;
  var entryCount = 0;
  for (final entry in entries) {
    entryCount++;
    final per100 = nutrientPer100gForItem(spec, entry.foodItem);
    if (per100 == null) continue;
    final amount = per100 * entry.quantityG / 100.0;
    if (amount <= 0) continue;
    total += amount;
    contributors.add(
      NutrientContribution(
        name: entry.foodItem.name,
        brand: entry.foodItem.brands,
        amount: amount,
        quantityG: entry.quantityG,
        share: 0, // filled once the total is known
      ),
    );
  }
  contributors.sort((a, b) => b.amount.compareTo(a.amount));
  final ranked = [
    for (final c in contributors)
      NutrientContribution(
        name: c.name,
        brand: c.brand,
        amount: c.amount,
        quantityG: c.quantityG,
        share: total > 0 ? c.amount / total : 0,
      ),
  ];
  return NutrientContributionBreakdown(
    spec: spec,
    contributors: ranked,
    total: total,
    entryCount: entryCount,
  );
}

/// Aggregates every catalog nutrient across a day's logged entries, scaling each
/// food's per-100g value by the logged quantity. A nutrient only counts entries
/// that actually carry data for it; if none do, its total is `null` ("no data").
List<NutrientTotal> aggregateNutrients(
  Iterable<NutritionEntry> entries, {
  List<NutrientSpec> catalog = kNutrientCatalog,
}) {
  final sums = <String, double>{};
  // Foods that reported each nutrient. A food with no data at all still counts
  // toward the denominator (its macros are unknown -> the day total is a floor).
  final reported = <String, int>{};
  var entryCount = 0;
  for (final entry in entries) {
    entryCount++;
    final factor = entry.quantityG / 100.0;
    for (final spec in catalog) {
      final per100 = nutrientPer100gForItem(spec, entry.foodItem);
      if (per100 == null) continue;
      sums[spec.key] = (sums[spec.key] ?? 0) + per100 * factor;
      reported[spec.key] = (reported[spec.key] ?? 0) + 1;
    }
  }
  return [
    for (final spec in catalog)
      NutrientTotal(
        spec: spec,
        amount: reported.containsKey(spec.key) ? sums[spec.key] : null,
        reportedCount: reported[spec.key] ?? 0,
        totalCount: entryCount,
      ),
  ];
}
