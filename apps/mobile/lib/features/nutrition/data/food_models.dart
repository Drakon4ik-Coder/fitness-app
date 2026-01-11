import 'dart:convert';

const String offSource = 'openfoodfacts';

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
    this.kcal100g,
    this.proteinG100g,
    this.carbsG100g,
    this.fatG100g,
    this.sugarsG100g,
    this.fiberG100g,
    this.saltG100g,
    this.servingSizeG,
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
  final double? kcal100g;
  final double? proteinG100g;
  final double? carbsG100g;
  final double? fatG100g;
  final double? sugarsG100g;
  final double? fiberG100g;
  final double? saltG100g;
  final double? servingSizeG;
  final String rawSourceJson;
  final Map<String, dynamic>? nutrimentsJson;
  final DateTime? lastUsedAt;
  final bool isFavorite;

  FoodItem copyWith({
    int? localId,
    int? backendId,
    String? source,
    String? externalId,
    String? barcode,
    String? name,
    String? brands,
    String? imageUrl,
    double? kcal100g,
    double? proteinG100g,
    double? carbsG100g,
    double? fatG100g,
    double? sugarsG100g,
    double? fiberG100g,
    double? saltG100g,
    double? servingSizeG,
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
      kcal100g: kcal100g ?? this.kcal100g,
      proteinG100g: proteinG100g ?? this.proteinG100g,
      carbsG100g: carbsG100g ?? this.carbsG100g,
      fatG100g: fatG100g ?? this.fatG100g,
      sugarsG100g: sugarsG100g ?? this.sugarsG100g,
      fiberG100g: fiberG100g ?? this.fiberG100g,
      saltG100g: saltG100g ?? this.saltG100g,
      servingSizeG: servingSizeG ?? this.servingSizeG,
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
      'kcal_100g': kcal100g,
      'protein_g_100g': proteinG100g,
      'carbs_g_100g': carbsG100g,
      'fat_g_100g': fatG100g,
      'sugars_g_100g': sugarsG100g,
      'fiber_g_100g': fiberG100g,
      'salt_g_100g': saltG100g,
      'serving_size_g': servingSizeG,
      'raw_source_json': rawSourceJson,
      'nutriments_json':
          nutrimentsJson == null ? null : jsonEncode(nutrimentsJson),
      'last_used_at': lastUsedAt?.toIso8601String(),
      'is_favorite': isFavorite ? 1 : 0,
    };
    return map;
  }

  Map<String, dynamic> toBackendPayload() {
    final Map<String, dynamic> payload = {
      'source': source,
      'external_id': externalId,
      'barcode': barcode ?? '',
      'name': name,
      'brands': brands,
      'image_url': imageUrl ?? '',
      'kcal_100g': kcal100g,
      'protein_g_100g': proteinG100g,
      'carbs_g_100g': carbsG100g,
      'fat_g_100g': fatG100g,
      'sugars_g_100g': sugarsG100g,
      'fiber_g_100g': fiberG100g,
      'salt_g_100g': saltG100g,
      'serving_size_g': servingSizeG,
      'raw_source_json': jsonDecode(rawSourceJson),
    };

    if (nutrimentsJson != null) {
      payload['nutriments_json'] = nutrimentsJson;
    }

    return payload;
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
      kcal100g: parseNullableDouble(map['kcal_100g']),
      proteinG100g: parseNullableDouble(map['protein_g_100g']),
      carbsG100g: parseNullableDouble(map['carbs_g_100g']),
      fatG100g: parseNullableDouble(map['fat_g_100g']),
      sugarsG100g: parseNullableDouble(map['sugars_g_100g']),
      fiberG100g: parseNullableDouble(map['fiber_g_100g']),
      saltG100g: parseNullableDouble(map['salt_g_100g']),
      servingSizeG: parseNullableDouble(map['serving_size_g']),
      rawSourceJson: (map['raw_source_json'] as String?) ?? '{}',
      nutrimentsJson: nutrimentsRaw == null
          ? null
          : jsonDecode(nutrimentsRaw) as Map<String, dynamic>,
      lastUsedAt: map['last_used_at'] == null
          ? null
          : DateTime.tryParse(map['last_used_at'] as String),
      isFavorite: (map['is_favorite'] as int? ?? 0) == 1,
    );
  }

  static FoodItem fromBackendSummary(Map<String, dynamic> map) {
    final backendId = map['id'] as int?;
    final barcode = map['barcode']?.toString();
    return FoodItem(
      backendId: backendId,
      source: offSource,
      externalId: barcode ?? backendId?.toString() ?? '',
      barcode: barcode,
      name: (map['name'] as String?) ?? '',
      brands: (map['brands'] as String?) ?? '',
      imageUrl: map['image_url'] as String?,
      kcal100g: parseNullableDouble(map['kcal_100g']),
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
                ? jsonDecode(nutrimentsRaw) as Map<String, dynamic>
                : null;
    return FoodItem(
      backendId: backendId,
      source: (map['source'] as String?) ?? offSource,
      externalId: (map['external_id'] as String?) ??
          barcode ??
          backendId?.toString() ??
          '',
      barcode: barcode,
      name: (map['name'] as String?) ?? '',
      brands: (map['brands'] as String?) ?? '',
      imageUrl: map['image_url'] as String?,
      kcal100g: parseNullableDouble(map['kcal_100g']),
      proteinG100g: parseNullableDouble(map['protein_g_100g']),
      carbsG100g: parseNullableDouble(map['carbs_g_100g']),
      fatG100g: parseNullableDouble(map['fat_g_100g']),
      sugarsG100g: parseNullableDouble(map['sugars_g_100g']),
      fiberG100g: parseNullableDouble(map['fiber_g_100g']),
      saltG100g: parseNullableDouble(map['salt_g_100g']),
      servingSizeG: parseNullableDouble(map['serving_size_g']),
      rawSourceJson: rawJson,
      nutrimentsJson: nutrimentsJson,
    );
  }
}
