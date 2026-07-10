import 'dart:convert';

import 'ciqual_raw_refs.dart';

const String offSource = 'openfoodfacts';

/// Source for user-created foods. Owner-scoped on the backend (private to
/// their creator) and synced through /foods/custom rather than the OFF
/// ingest/check flow; `externalId` is a client-generated id.
const String customSource = 'custom';

/// The four meal slots a day log is grouped into.
///
/// [wireName] is the `meal_type` string used by the API and the local store.
/// It is spelled out (rather than relying on the enum's own [name]) so a
/// Dart-side rename can never silently change the wire contract.
enum MealType {
  breakfast('breakfast', 'Breakfast'),
  lunch('lunch', 'Lunch'),
  dinner('dinner', 'Dinner'),
  snacks('snacks', 'Snacks');

  const MealType(this.wireName, this.label);

  /// Backend `meal_type` value and local-store key.
  final String wireName;

  /// User-facing display name.
  final String label;

  /// The meal for a wire string, or null for an unknown value.
  static MealType? fromWire(String value) {
    for (final meal in values) {
      if (meal.wireName == value) return meal;
    }
    return null;
  }
}

double? parseNullableDouble(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return double.tryParse(trimmed);
  }
  return null;
}

Object _decodeRawSourceJson(String rawSourceJson) {
  final trimmed = rawSourceJson.trim();
  if (trimmed.isEmpty) {
    return <String, dynamic>{};
  }
  try {
    final decoded = jsonDecode(trimmed);
    return decoded ?? <String, dynamic>{};
  } on FormatException {
    return <String, dynamic>{};
  }
}

/// A food that is naturally counted in discrete pieces (an egg, a burger, a
/// slice) rather than by weight. OFF never stores nutrition "per piece" — it is
/// always per 100 g — so a piece is just a named portion of a known gram weight
/// derived from the free-text `serving_size` (e.g. "2 eggs (105 g)").
class PieceDescriptor {
  const PieceDescriptor({required this.gramsPerPiece, required this.unit});

  /// Weight of a single piece in grams (servingGrams / pieceCount).
  final double gramsPerPiece;

  /// Singular, lower-cased noun for one piece, e.g. "egg", "burger", "slice".
  final String unit;
}

// Measure words that look like a leading count but are units/portions, not
// countable pieces. "2 eggs" is a piece; "1 serving"/"100 g"/"1 cup" is not.
const Set<String> _measureWords = {
  'g',
  'gr',
  'gram',
  'grams',
  'kg',
  'mg',
  'ml',
  'l',
  'cl',
  'dl',
  'oz',
  'lb',
  'fl',
  'floz',
  'cup',
  'cups',
  'tbsp',
  'tsp',
  'tbs',
  'teaspoon',
  'teaspoons',
  'tablespoon',
  'tablespoons',
  'serving',
  'servings',
  'serv',
  'portion',
  'portions',
  'glass',
  'glasses',
};

final RegExp _gramUnitRegExp = RegExp(
  r'([\d.,]+)\s*(?:g|ml)\b',
  caseSensitive: false,
);

// The subset of [_measureWords] whose amounts really are grams/millilitres.
// Any other measure word states an amount in a unit this parser does not
// convert, so a bare number next to it must never be read as grams.
const Set<String> _gramEquivalentWords = {'g', 'gr', 'gram', 'grams', 'ml'};

/// A leading `count noun` at the start of a serving text where the noun is a
/// countable piece, e.g. "2 eggs ..." -> (2, "egg"). Returns null for measure
/// words ("1 serving", "100 g") so they are never mistaken for pieces.
({double count, String unit})? parseLeadingPiece(String? text) {
  if (text == null) return null;
  final match = RegExp(
    r'^\s*([\d]+(?:[.,]\d+)?)\s*([a-zA-Z][a-zA-Z\-]*)',
  ).firstMatch(text.trim());
  if (match == null) return null;
  final count = double.tryParse(match.group(1)!.replaceAll(',', '.'));
  if (count == null || count <= 0) return null;
  var noun = match.group(2)!.toLowerCase();
  if (_measureWords.contains(noun)) return null;
  // Singularize a trailing plural "s" for display ("eggs" -> "egg") while
  // keeping short nouns intact ("bar" stays "bar").
  if (noun.length > 3 && noun.endsWith('s')) {
    noun = noun.substring(0, noun.length - 1);
  }
  return (count: count, unit: noun);
}

/// The grams (or millilitres, treated equivalently) explicitly stated in a
/// serving text. Prefers a number attached to a g/ml unit ("1 egg (50 g)" -> 50,
/// "355ml" -> 355). Falls back to a bare number only when the text has no
/// leading piece count the number could really be — so "30" -> 30 but "1 egg"
/// -> null (the "1" counts eggs, not grams). This is what stops a bare
/// "1 egg" from being read as a 1-gram serving. Texts using a measure word in
/// a unit we don't convert ("100 mg", "1 oz", "2 cups") are unparseable — the
/// bare number would be off by the unit's conversion factor.
double? gramsFromServingText(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final unitMatch = _gramUnitRegExp.firstMatch(trimmed);
  if (unitMatch != null) {
    return double.tryParse(unitMatch.group(1)!.replaceAll(',', '.'));
  }
  // No explicit g/ml amount anywhere in the text: if it mentions any other
  // mass/volume unit, its numbers are in that unit, not grams — reading
  // "100 mg" as 100 g would be a 1000x error.
  for (final match in RegExp(r'[a-zA-Z]+').allMatches(trimmed)) {
    final word = match.group(0)!.toLowerCase();
    if (_measureWords.contains(word) && !_gramEquivalentWords.contains(word)) {
      return null;
    }
  }
  if (parseLeadingPiece(trimmed) != null) return null;
  final any = RegExp(r'([\d.,]+)').firstMatch(trimmed);
  if (any == null) return null;
  return double.tryParse(any.group(1)!.replaceAll(',', '.'));
}

/// Derives a [PieceDescriptor] from OFF's free-text `serving_size`. Requires
/// both a leading piece count AND an explicit g/ml weight in the text (e.g.
/// "2 eggs (105 g)"), so a bare "1 egg" yields no piece rather than a bogus
/// 1 g/egg. Conservative by design: a missing piece is better than a wrong one.
PieceDescriptor? parsePieceDescriptor(String? servingSizeText) {
  final leading = parseLeadingPiece(servingSizeText);
  if (leading == null) return null;
  final unitMatch = _gramUnitRegExp.firstMatch(servingSizeText!.trim());
  if (unitMatch == null) return null;
  final grams = double.tryParse(unitMatch.group(1)!.replaceAll(',', '.'));
  if (grams == null || grams <= 0) return null;
  final gramsPerPiece = grams / leading.count;
  // Guard against implausible per-piece weights from malformed text.
  if (gramsPerPiece < 1 || gramsPerPiece > 2000) return null;
  return PieceDescriptor(gramsPerPiece: gramsPerPiece, unit: leading.unit);
}

/// Marker value for [FoodItem.nutritionBasis]: the label's per-100g values
/// describe the food *after cooking* even though it is sold raw. Common on UK
/// fresh meat ("typical values per 100 g grilled"), where contributors copy
/// the grilled column into OFF's plain per-100g fields — OFF's `_prepared`
/// nutriment fields go unused on meat, so there is no explicit signal.
/// A null [FoodItem.nutritionBasis] means the values are per 100 g as sold.
const String cookedNutritionBasis = 'cooked';

/// Fraction of the raw weight left after cooking (water loss is ~25% for
/// minced meat, steaks, and poultry). Converts a raw-weighed amount into the
/// cooked-equivalent grams that per-100g-cooked label values scale against.
const double kCookedYieldFactor = 0.75;

// OFF category tags for fresh/raw meat and fish, where raw per-100g protein
// has a hard physical ceiling (raw muscle is ~70-75% water -> ~17-24 g).
const Set<String> _freshMeatFishTags = {
  'en:meats',
  'en:beef',
  'en:pork',
  'en:lamb-meat',
  'en:veal-meat',
  'en:poultries',
  'en:fishes',
  'en:seafood',
};

// Categories that are legitimately protein-dense as sold (cured, dried,
// canned, smoked, or sold already cooked) — never flagged as cooked-basis.
const Set<String> _preparedMeatFishTags = {
  'en:prepared-meats',
  'en:charcuteries',
  'en:hams',
  'en:sausages',
  'en:dried-meats',
  'en:cooked-meats',
  'en:canned-meats',
  'en:canned-fishes',
  'en:smoked-fishes',
  'en:dried-fishes',
};

// Raw muscle meat/fish tops out around 24 g protein per 100 g; anything above
// is only reachable after cooking water loss (or curing/drying, excluded via
// category above).
const double _rawProteinCeilingG100g = 25.0;

// Label protein this far above the CIQUAL raw reference means the label's
// cooked column was entered: cooking concentrates protein ~1.3-1.4x through
// water loss, while entry noise across fat grades stays within ~10%.
const double _cookedVsRawProteinRatio = 1.25;

// A raw reference below this (shellfish etc.) is too small a denominator for
// a meaningful ratio; such foods fall back to the category heuristic.
const double _minCiqualReferenceProteinG100g = 10.0;

/// Heuristic for labels that state nutrition per cooked weight on a product
/// sold raw. Two tiers:
///
/// 1. CIQUAL cross-check — when OFF's Agribalyse match ([ciqualCode]) is a
///    known *raw* food, its reference protein is authoritative: a label far
///    above it carries the cooked column, one near it is genuinely raw.
/// 2. Category fallback — a fresh meat/fish category whose per-100g protein
///    exceeds the raw physical ceiling.
///
/// Conservative by design — a missed flag just means grams are read as-sold,
/// like today.
bool detectCookedNutritionBasis({
  required List<String> categoriesTags,
  required double? proteinG100g,
  int? ciqualCode,
}) {
  if (proteinG100g == null) return false;
  final referenceProtein = ciqualCode == null
      ? null
      : ciqualRawProteinG100g[ciqualCode];
  if (referenceProtein != null &&
      referenceProtein >= _minCiqualReferenceProteinG100g) {
    return proteinG100g / referenceProtein >= _cookedVsRawProteinRatio;
  }
  if (proteinG100g < _rawProteinCeilingG100g) return false;
  if (!categoriesTags.any(_freshMeatFishTags.contains)) return false;
  if (categoriesTags.any(_preparedMeatFishTags.contains)) return false;
  return true;
}

/// The CIQUAL food code from an OFF product's Agribalyse match
/// (`ecoscore_data.agribalyse`), or null when the product has none.
int? ciqualCodeFromOffProduct(Map<String, dynamic> product) {
  final ecoscore = product['ecoscore_data'];
  if (ecoscore is! Map) return null;
  final agribalyse = ecoscore['agribalyse'];
  if (agribalyse is! Map) return null;
  for (final key in const [
    'agribalyse_food_code',
    'code',
    'agribalyse_proxy_food_code',
  ]) {
    final code = int.tryParse(agribalyse[key]?.toString() ?? '');
    if (code != null) return code;
  }
  return null;
}

// Pulls the Agribalyse/CIQUAL code out of a stored OFF raw-source blob,
// whether the product sits at the top level or nested under `product`.
int? _ciqualCodeFromRaw(String rawSourceJson) {
  final decoded = _decodeRawSourceJson(rawSourceJson);
  if (decoded is! Map) return null;
  final direct = ciqualCodeFromOffProduct(decoded.cast<String, dynamic>());
  if (direct != null) return direct;
  final product = decoded['product'];
  if (product is Map) {
    return ciqualCodeFromOffProduct(product.cast<String, dynamic>());
  }
  return null;
}

// Pulls `categories_tags` out of a stored OFF raw-source blob, whether it
// sits at the top level or nested under `product`.
List<String> _categoriesTagsFromRaw(String rawSourceJson) {
  final decoded = _decodeRawSourceJson(rawSourceJson);
  if (decoded is! Map) return const [];
  dynamic tags = decoded['categories_tags'];
  if (tags is! List) {
    final product = decoded['product'];
    if (product is Map) tags = product['categories_tags'];
  }
  if (tags is! List) return const [];
  return tags.whereType<String>().toList();
}

// Pulls the free-text `serving_size` out of a stored OFF raw-source blob,
// whether it sits at the top level or nested under `product`.
String? _servingSizeTextFromRaw(String rawSourceJson) {
  final decoded = _decodeRawSourceJson(rawSourceJson);
  if (decoded is! Map) return null;
  final direct = decoded['serving_size'];
  if (direct is String && direct.trim().isNotEmpty) return direct;
  final product = decoded['product'];
  if (product is Map) {
    final nested = product['serving_size'];
    if (nested is String && nested.trim().isNotEmpty) return nested;
  }
  return null;
}

DateTime? _parseBackendDateTime(dynamic value) {
  if (value is! String || value.trim().isEmpty) return null;
  return DateTime.tryParse(value);
}

Map<String, dynamic>? _decodeNutrimentsJson(String? nutrimentsRaw) {
  if (nutrimentsRaw == null) {
    return null;
  }
  final trimmed = nutrimentsRaw.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } on FormatException {
    return null;
  }
  return null;
}

class FoodItem {
  FoodItem({
    this.localId,
    this.backendId,
    required this.source,
    required this.externalId,
    this.barcode,
    required this.name,
    required this.brands,
    this.imageUrl,
    this.imageSignature,
    this.contentHash = '',
    this.kcal100g,
    this.proteinG100g,
    this.carbsG100g,
    this.fatG100g,
    this.sugarsG100g,
    this.fiberG100g,
    this.saltG100g,
    this.servingSizeG,
    this.gramsPerPiece,
    this.pieceUnit,
    this.nutritionBasis,
    this.overridesBackendId,
    this.overridesBarcode,
    this.communityVerifiedAt,
    this.completeness,
    required this.rawSourceJson,
    this.nutrimentsJson,
    this.lastUsedAt,
    this.isFavorite = false,
  });

  final int? localId;
  final int? backendId;
  final String source;
  final String externalId;
  final String? barcode;
  final String name;
  final String brands;
  final String? imageUrl;
  final String? imageSignature;
  final String contentHash;
  final double? kcal100g;
  final double? proteinG100g;
  final double? carbsG100g;
  final double? fatG100g;
  final double? sugarsG100g;
  final double? fiberG100g;
  final double? saltG100g;
  final double? servingSizeG;
  // Weight of one countable piece in grams, when the food is naturally counted
  // in pieces (an egg, a burger). Null for weight-only foods.
  final double? gramsPerPiece;
  // Singular noun for one piece ("egg", "burger"), paired with [gramsPerPiece].
  final String? pieceUnit;
  // [cookedNutritionBasis] when the label's per-100g values describe the
  // cooked food while the product is sold raw; null = per 100 g as sold.
  final String? nutritionBasis;
  // Fork-on-edit (KAN-31): backend id of the global item this custom food
  // shadows for its owner; null for ordinary foods.
  final int? overridesBackendId;
  // Barcode of the shadowed item, kept locally so a scan can resolve straight
  // to the override without a backend round-trip. Not sent to the backend.
  final String? overridesBarcode;
  // When the community convergence system (KAN-32) promoted user-agreed
  // nutrition into this item's shared values; null for unverified foods.
  // Server-owned — read from API responses, never sent back.
  final DateTime? communityVerifiedAt;
  // OFF data `completeness` in [0,1] for ranking/filtering live search results.
  // Transient: only set on freshly mapped OFF hits, never persisted.
  final double? completeness;
  final String rawSourceJson;
  final Map<String, dynamic>? nutrimentsJson;
  final DateTime? lastUsedAt;
  final bool isFavorite;

  bool get isCookedBasis => nutritionBasis == cookedNutritionBasis;

  bool get isCustom => source == customSource;

  bool get isOverride => isCustom && overridesBackendId != null;

  bool get isCommunityVerified => communityVerifiedAt != null;

  FoodItem copyWith({
    int? localId,
    int? backendId,
    String? source,
    String? externalId,
    String? barcode,
    String? name,
    String? brands,
    String? imageUrl,
    String? imageSignature,
    String? contentHash,
    double? kcal100g,
    double? proteinG100g,
    double? carbsG100g,
    double? fatG100g,
    double? sugarsG100g,
    double? fiberG100g,
    double? saltG100g,
    double? servingSizeG,
    double? gramsPerPiece,
    String? pieceUnit,
    String? nutritionBasis,
    int? overridesBackendId,
    String? overridesBarcode,
    DateTime? communityVerifiedAt,
    double? completeness,
    String? rawSourceJson,
    Map<String, dynamic>? nutrimentsJson,
    DateTime? lastUsedAt,
    bool? isFavorite,
  }) {
    return FoodItem(
      localId: localId ?? this.localId,
      backendId: backendId ?? this.backendId,
      source: source ?? this.source,
      externalId: externalId ?? this.externalId,
      barcode: barcode ?? this.barcode,
      name: name ?? this.name,
      brands: brands ?? this.brands,
      imageUrl: imageUrl ?? this.imageUrl,
      imageSignature: imageSignature ?? this.imageSignature,
      contentHash: contentHash ?? this.contentHash,
      kcal100g: kcal100g ?? this.kcal100g,
      proteinG100g: proteinG100g ?? this.proteinG100g,
      carbsG100g: carbsG100g ?? this.carbsG100g,
      fatG100g: fatG100g ?? this.fatG100g,
      sugarsG100g: sugarsG100g ?? this.sugarsG100g,
      fiberG100g: fiberG100g ?? this.fiberG100g,
      saltG100g: saltG100g ?? this.saltG100g,
      servingSizeG: servingSizeG ?? this.servingSizeG,
      gramsPerPiece: gramsPerPiece ?? this.gramsPerPiece,
      pieceUnit: pieceUnit ?? this.pieceUnit,
      nutritionBasis: nutritionBasis ?? this.nutritionBasis,
      overridesBackendId: overridesBackendId ?? this.overridesBackendId,
      overridesBarcode: overridesBarcode ?? this.overridesBarcode,
      communityVerifiedAt: communityVerifiedAt ?? this.communityVerifiedAt,
      completeness: completeness ?? this.completeness,
      rawSourceJson: rawSourceJson ?? this.rawSourceJson,
      nutrimentsJson: nutrimentsJson ?? this.nutrimentsJson,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  Map<String, Object?> toDbMap({bool includeId = false}) {
    final map = <String, Object?>{
      if (includeId && localId != null) 'id': localId,
      'backend_id': backendId,
      'source': source,
      'external_id': externalId,
      'barcode': barcode,
      'name': name,
      'brands': brands,
      'image_url': imageUrl,
      'image_signature': imageSignature,
      'content_hash': contentHash,
      'kcal_100g': kcal100g,
      'protein_g_100g': proteinG100g,
      'carbs_g_100g': carbsG100g,
      'fat_g_100g': fatG100g,
      'sugars_g_100g': sugarsG100g,
      'fiber_g_100g': fiberG100g,
      'salt_g_100g': saltG100g,
      'serving_size_g': servingSizeG,
      'grams_per_piece': gramsPerPiece,
      'piece_unit': pieceUnit,
      'nutrition_basis': nutritionBasis,
      'overrides_backend_id': overridesBackendId,
      'overrides_barcode': overridesBarcode,
      'community_verified_at': communityVerifiedAt?.toIso8601String(),
      'raw_source_json': rawSourceJson,
      'nutriments_json': nutrimentsJson == null
          ? null
          : jsonEncode(nutrimentsJson),
      'last_used_at': lastUsedAt?.toIso8601String(),
      'is_favorite': isFavorite ? 1 : 0,
    };
    return map;
  }

  Map<String, dynamic> toBackendPayload() {
    double? round(double? val) {
      if (val == null) return null;
      return double.parse(val.toStringAsFixed(2));
    }

    final Map<String, dynamic> payload = {
      'source': source,
      'external_id': externalId,
      'barcode': barcode ?? '',
      'name': name,
      'brands': brands,
      'image_url': imageUrl ?? '',
      'kcal_100g': round(kcal100g),
      'protein_g_100g': round(proteinG100g),
      'carbs_g_100g': round(carbsG100g),
      'fat_g_100g': round(fatG100g),
      'sugars_g_100g': round(sugarsG100g),
      'fiber_g_100g': round(fiberG100g),
      'salt_g_100g': round(saltG100g),
      'serving_size_g': round(servingSizeG),
      'raw_source_json': _decodeRawSourceJson(rawSourceJson),
    };

    if (contentHash.isNotEmpty) {
      payload['content_hash'] = contentHash;
    }
    if (imageSignature != null && imageSignature!.trim().isNotEmpty) {
      payload['image_signature'] = imageSignature;
    }

    if (nutrimentsJson != null) {
      payload['nutriments_json'] = nutrimentsJson;
    }

    return payload;
  }

  /// Payload for the owner-scoped /foods/custom upsert. Unlike
  /// [toBackendPayload], carries no source/barcode/raw JSON — the backend
  /// fixes those for custom foods.
  Map<String, dynamic> toCustomPayload() {
    double? round(double? val) {
      if (val == null) return null;
      return double.parse(val.toStringAsFixed(2));
    }

    return {
      'external_id': externalId,
      'name': name,
      'brands': brands,
      'kcal_100g': round(kcal100g),
      'protein_g_100g': round(proteinG100g),
      'carbs_g_100g': round(carbsG100g),
      'fat_g_100g': round(fatG100g),
      'sugars_g_100g': round(sugarsG100g),
      'fiber_g_100g': round(fiberG100g),
      'salt_g_100g': round(saltG100g),
      'serving_size_g': round(servingSizeG),
      if (nutrimentsJson != null) 'nutriments_json': nutrimentsJson,
      if (overridesBackendId != null) 'overrides_food': overridesBackendId,
    };
  }

  static FoodItem fromDbMap(Map<String, Object?> map) {
    final nutrimentsRaw = map['nutriments_json'] as String?;
    return FoodItem(
      localId: map['id'] as int?,
      backendId: map['backend_id'] as int?,
      source: (map['source'] as String?) ?? offSource,
      externalId: (map['external_id'] as String?) ?? '',
      barcode: map['barcode'] as String?,
      name: (map['name'] as String?) ?? '',
      brands: (map['brands'] as String?) ?? '',
      imageUrl: map['image_url'] as String?,
      imageSignature: map['image_signature'] as String?,
      contentHash: (map['content_hash'] as String?) ?? '',
      kcal100g: parseNullableDouble(map['kcal_100g']),
      proteinG100g: parseNullableDouble(map['protein_g_100g']),
      carbsG100g: parseNullableDouble(map['carbs_g_100g']),
      fatG100g: parseNullableDouble(map['fat_g_100g']),
      sugarsG100g: parseNullableDouble(map['sugars_g_100g']),
      fiberG100g: parseNullableDouble(map['fiber_g_100g']),
      saltG100g: parseNullableDouble(map['salt_g_100g']),
      servingSizeG: parseNullableDouble(map['serving_size_g']),
      gramsPerPiece: parseNullableDouble(map['grams_per_piece']),
      pieceUnit: map['piece_unit'] as String?,
      nutritionBasis: map['nutrition_basis'] as String?,
      overridesBackendId: map['overrides_backend_id'] as int?,
      overridesBarcode: map['overrides_barcode'] as String?,
      communityVerifiedAt: map['community_verified_at'] == null
          ? null
          : DateTime.tryParse(map['community_verified_at'] as String),
      rawSourceJson: (map['raw_source_json'] as String?) ?? '{}',
      nutrimentsJson: _decodeNutrimentsJson(nutrimentsRaw),
      lastUsedAt: map['last_used_at'] == null
          ? null
          : DateTime.tryParse(map['last_used_at'] as String),
      isFavorite: (map['is_favorite'] as int? ?? 0) == 1,
    );
  }

  static FoodItem fromBackendSummary(Map<String, dynamic> map) {
    final backendId = map['id'] as int?;
    final barcode = map['barcode']?.toString();
    final imageUrl = map['image_url'] as String?;
    return FoodItem(
      backendId: backendId,
      source: (map['source'] as String?) ?? offSource,
      externalId:
          (map['external_id'] as String?) ??
          barcode ??
          backendId?.toString() ??
          '',
      barcode: barcode,
      name: (map['name'] as String?) ?? '',
      brands: (map['brands'] as String?) ?? '',
      imageUrl: imageUrl,
      kcal100g: parseNullableDouble(map['kcal_100g']),
      contentHash: (map['content_hash'] as String?) ?? '',
      imageSignature: map['image_signature'] as String?,
      overridesBackendId: map['overrides_food'] as int?,
      communityVerifiedAt: _parseBackendDateTime(map['community_verified_at']),
      rawSourceJson: '{}',
      nutrimentsJson: null,
    );
  }

  static FoodItem fromBackendDetail(Map<String, dynamic> map) {
    final backendId = map['id'] as int?;
    final barcode = map['barcode']?.toString();
    final rawSource = map['raw_source_json'];
    final nutrimentsRaw = map['nutriments_json'];
    final rawJson = rawSource is String
        ? rawSource
        : jsonEncode(rawSource ?? <String, dynamic>{});
    final Map<String, dynamic>? nutrimentsJson =
        nutrimentsRaw is Map<String, dynamic>
        ? nutrimentsRaw
        : nutrimentsRaw is String
        ? _decodeNutrimentsJson(nutrimentsRaw)
        : null;
    // The backend has no dedicated piece columns, so re-derive the piece
    // descriptor from the round-tripped raw serving_size text.
    final servingSizeG = parseNullableDouble(map['serving_size_g']);
    final piece = parsePieceDescriptor(_servingSizeTextFromRaw(rawJson));
    // Likewise the cooked-basis marker: re-derived from the round-tripped
    // categories tags and Agribalyse match rather than stored in a backend
    // column.
    final proteinG100g = parseNullableDouble(map['protein_g_100g']);
    final cookedBasis = detectCookedNutritionBasis(
      categoriesTags: _categoriesTagsFromRaw(rawJson),
      proteinG100g: proteinG100g,
      ciqualCode: _ciqualCodeFromRaw(rawJson),
    );
    return FoodItem(
      backendId: backendId,
      source: (map['source'] as String?) ?? offSource,
      externalId:
          (map['external_id'] as String?) ??
          barcode ??
          backendId?.toString() ??
          '',
      barcode: barcode,
      name: (map['name'] as String?) ?? '',
      brands: (map['brands'] as String?) ?? '',
      imageUrl: map['image_url'] as String?,
      imageSignature: map['image_signature'] as String?,
      contentHash: (map['content_hash'] as String?) ?? '',
      kcal100g: parseNullableDouble(map['kcal_100g']),
      proteinG100g: proteinG100g,
      carbsG100g: parseNullableDouble(map['carbs_g_100g']),
      fatG100g: parseNullableDouble(map['fat_g_100g']),
      sugarsG100g: parseNullableDouble(map['sugars_g_100g']),
      fiberG100g: parseNullableDouble(map['fiber_g_100g']),
      saltG100g: parseNullableDouble(map['salt_g_100g']),
      servingSizeG: servingSizeG,
      gramsPerPiece: piece?.gramsPerPiece,
      pieceUnit: piece?.unit,
      nutritionBasis: cookedBasis ? cookedNutritionBasis : null,
      overridesBackendId: map['overrides_food'] as int?,
      communityVerifiedAt: _parseBackendDateTime(map['community_verified_at']),
      rawSourceJson: rawJson,
      nutrimentsJson: nutrimentsJson,
    );
  }
}
