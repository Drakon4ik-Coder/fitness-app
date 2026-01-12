import 'food_models.dart';

class OffMapper {
  FoodItem mapProduct({
    required Map<String, dynamic> product,
    required String rawJson,
  }) {
    final barcode = product['code']?.toString();
    final name = _bestName(product);
    final brands = (product['brands'] as String?)?.trim() ?? '';
    final imageUrl = product['image_url'] ??
        product['image_front_url'] ??
        product['image_front_small_url'] ??
        '';

    final nutriments = product['nutriments'];
    final nutrimentsJson =
        nutriments is Map<String, dynamic> ? nutriments : null;

    final kcal100g = _kcalPer100g(nutrimentsJson);
    final protein = _readNutriment(nutrimentsJson, 'proteins_100g');
    final carbs = _readNutriment(nutrimentsJson, 'carbohydrates_100g');
    final fat = _readNutriment(nutrimentsJson, 'fat_100g');
    final sugars = _readNutriment(nutrimentsJson, 'sugars_100g');
    final fiber = _readNutriment(nutrimentsJson, 'fiber_100g');
    final salt = _readNutriment(nutrimentsJson, 'salt_100g');
    final servingSize = _parseServingSize(product['serving_size'] as String?);

    return FoodItem(
      source: offSource,
      externalId: barcode ?? '',
      barcode: barcode,
      name: name,
      brands: brands,
      imageUrl: imageUrl is String && imageUrl.isNotEmpty ? imageUrl : null,
      kcal100g: kcal100g,
      proteinG100g: protein,
      carbsG100g: carbs,
      fatG100g: fat,
      sugarsG100g: sugars,
      fiberG100g: fiber,
      saltG100g: salt,
      servingSizeG: servingSize,
      rawSourceJson: rawJson,
      nutrimentsJson: nutrimentsJson,
    );
  }

  String _bestName(Map<String, dynamic> product) {
    final lang = product['lang'];
    final nameEn = product['product_name_en'];
    if (lang is String &&
        lang.toLowerCase() != 'en' &&
        nameEn is String &&
        nameEn.trim().isNotEmpty) {
      return nameEn.trim();
    }
    final candidates = [
      product['product_name_en'],
      product['product_name'],
      product['generic_name'],
    ];
    for (final candidate in candidates) {
      if (candidate is String && candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
    }
    return 'Unnamed product';
  }

  double? _kcalPer100g(Map<String, dynamic>? nutriments) {
    final energy = _readNutriment(nutriments, 'energy-kcal_100g') ??
        _readNutriment(nutriments, 'energy-kcal_value');
    if (energy != null) {
      return energy;
    }
    final protein = _readNutriment(nutriments, 'proteins_100g') ?? 0;
    final carbs = _readNutriment(nutriments, 'carbohydrates_100g') ?? 0;
    final fat = _readNutriment(nutriments, 'fat_100g') ?? 0;
    if (protein == 0 && carbs == 0 && fat == 0) {
      return null;
    }
    return 4 * protein + 4 * carbs + 9 * fat;
  }

  double? _readNutriment(Map<String, dynamic>? nutriments, String key) {
    if (nutriments == null) {
      return null;
    }
    return parseNullableDouble(nutriments[key]);
  }

  double? _parseServingSize(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    final match = RegExp(r'([\d.,]+)').firstMatch(value);
    if (match == null) {
      return null;
    }
    final number = match.group(1)?.replaceAll(',', '.');
    if (number == null) {
      return null;
    }
    return double.tryParse(number);
  }
}
