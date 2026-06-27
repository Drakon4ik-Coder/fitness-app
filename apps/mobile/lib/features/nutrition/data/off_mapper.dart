import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'food_models.dart';

const String _offImageBase = 'https://images.openfoodfacts.org/images/products';

class _ImageResult {
  const _ImageResult({this.url, this.signature});
  final String? url;
  final String? signature;
}

class OffMapper {
  FoodItem mapProduct({
    required Map<String, dynamic> product,
    required String rawJson,
    String? localeLanguage,
  }) {
    final barcode = product['code']?.toString();
    final name = _bestName(product);
    final brands = _brandsValue(product['brands']) ?? '';
    final locale = localeLanguage?.trim().toLowerCase();
    final result = _selectImage(product, locale);

    final nutriments = product['nutriments'];
    final nutrimentsJson = nutriments is Map<String, dynamic>
        ? nutriments
        : null;

    final kcal100g = _kcalPer100g(nutrimentsJson);
    final protein = _readNutriment(nutrimentsJson, 'proteins_100g');
    final carbs = _readNutriment(nutrimentsJson, 'carbohydrates_100g');
    final fat = _readNutriment(nutrimentsJson, 'fat_100g');
    final sugars = _readNutriment(nutrimentsJson, 'sugars_100g');
    final fiber = _readNutriment(nutrimentsJson, 'fiber_100g');
    final salt = _readNutriment(nutrimentsJson, 'salt_100g');
    // `serving_quantity` is OFF's reliable numeric grams-per-serving. Fall back
    // to parsing the free-text `serving_size` only when it's missing, since that
    // text often starts with a piece count (e.g. "1 burger (215 g)") that would
    // otherwise be mistaken for the gram weight.
    final servingSize =
        _parseServingQuantity(product['serving_quantity']) ??
        _parseServingSize(product['serving_size']);
    final imageSignature = result.signature;
    final contentHash = _buildContentHash(
      source: offSource,
      externalId: barcode ?? '',
      name: name,
      brands: brands,
      kcal100g: kcal100g,
      protein: protein,
      carbs: carbs,
      fat: fat,
      sugars: sugars,
      fiber: fiber,
      salt: salt,
      servingSizeG: servingSize,
      imageSignature: imageSignature,
    );

    return FoodItem(
      source: offSource,
      externalId: barcode ?? '',
      barcode: barcode,
      name: name,
      brands: brands,
      imageUrl: result.url != null && result.url!.isNotEmpty
          ? result.url
          : null,
      imageSignature: imageSignature,
      contentHash: contentHash,
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

  // Priority 1: most recently uploaded org- image (full-res original).
  // Priority 2: selected front image at full resolution.
  _ImageResult _selectImage(Map<String, dynamic> product, String? locale) {
    final images = _asMap(product['images']);
    final barcode = product['code']?.toString();
    if (images == null || barcode == null || barcode.trim().isEmpty) {
      return const _ImageResult();
    }
    final basePath = _imageBasePath(barcode.trim());

    String? orgId;
    int? orgT;
    for (final entry in images.entries) {
      final key = entry.key.toString();
      if (!RegExp(r'^\d+$').hasMatch(key)) continue;
      final data = _asMap(entry.value);
      if (data == null) continue;
      final uploader = data['uploader'];
      if (uploader is! String || !uploader.startsWith('org-')) continue;
      final rawT = data['uploaded_t'];
      final t = rawT is int ? rawT : int.tryParse(rawT.toString()) ?? 0;
      if (orgT == null || t > orgT) {
        orgT = t;
        orgId = key;
      }
    }
    if (orgId != null) {
      return _ImageResult(
        url: '$_offImageBase/$basePath/$orgId.jpg',
        signature: orgId,
      );
    }

    final lang = _pickFrontLang(images, locale);
    if (lang == null) return const _ImageResult();
    final frontData = _asMap(images['front_$lang']);
    if (frontData == null) return const _ImageResult();
    final rev = frontData['rev'];
    if (rev == null) return const _ImageResult();
    final revStr = rev.toString();
    return _ImageResult(
      url: '$_offImageBase/$basePath/front_$lang.$revStr.full.jpg',
      signature: 'front_$lang.$revStr',
    );
  }

  String? _pickFrontLang(Map<String, dynamic> images, String? locale) {
    final langs = images.keys
        .whereType<String>()
        .where((k) => k.startsWith('front_'))
        .map((k) => k.substring(6))
        .where((l) => l.isNotEmpty)
        .toList();
    if (langs.isEmpty) return null;
    final normalized = locale?.toLowerCase();
    if (normalized != null && langs.contains(normalized)) return normalized;
    if (langs.contains('en')) return 'en';
    return langs.first;
  }

  String _imageBasePath(String barcode) {
    final digits = barcode.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return barcode;
    final padded = digits.padLeft(13, '0');
    final part1 = padded.substring(0, 3);
    final part2 = padded.substring(3, 6);
    final part3 = padded.substring(6, 9);
    final part4 = padded.substring(9);
    return '$part1/$part2/$part3/$part4';
  }

  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map) return value.cast<String, dynamic>();
    return null;
  }

  String? _stringValue(dynamic value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  // The barcode endpoint returns brands as a comma-separated string, while the
  // Search-a-licious endpoint returns them as a list. Normalize both to a
  // single comma-separated string.
  String? _brandsValue(dynamic value) {
    if (value is List) {
      final joined = value
          .map((e) => e?.toString().trim() ?? '')
          .where((e) => e.isNotEmpty)
          .join(', ');
      return joined.isEmpty ? null : joined;
    }
    return _stringValue(value);
  }

  String _buildContentHash({
    required String source,
    required String externalId,
    required String name,
    required String brands,
    required double? kcal100g,
    required double? protein,
    required double? carbs,
    required double? fat,
    required double? sugars,
    required double? fiber,
    required double? salt,
    required double? servingSizeG,
    required String? imageSignature,
  }) {
    final payload = <String, String>{
      'source': source,
      'external_id': externalId.trim(),
      'name': name.trim(),
      'brands': brands.trim(),
      'kcal_100g': _normalizeNumber(kcal100g),
      'protein_g_100g': _normalizeNumber(protein),
      'carbs_g_100g': _normalizeNumber(carbs),
      'fat_g_100g': _normalizeNumber(fat),
      'sugars_g_100g': _normalizeNumber(sugars),
      'fiber_g_100g': _normalizeNumber(fiber),
      'salt_g_100g': _normalizeNumber(salt),
      'serving_size_g': _normalizeNumber(servingSizeG),
      'image_signature': imageSignature?.trim() ?? '',
    };
    final encoded = jsonEncode(payload);
    return sha256.convert(utf8.encode(encoded)).toString();
  }

  String _normalizeNumber(double? value) {
    if (value == null) return '';
    final fixed = value.toStringAsFixed(3);
    return fixed
        .replaceFirst(RegExp(r'\.0+$'), '')
        .replaceFirst(RegExp(r'(\.\d*[1-9])0+$'), r'$1');
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
    final energy =
        _readNutriment(nutriments, 'energy-kcal_100g') ??
        _readNutriment(nutriments, 'energy-kcal_value');
    if (energy != null) return energy;
    final protein = _readNutriment(nutriments, 'proteins_100g') ?? 0;
    final carbs = _readNutriment(nutriments, 'carbohydrates_100g') ?? 0;
    final fat = _readNutriment(nutriments, 'fat_100g') ?? 0;
    if (protein == 0 && carbs == 0 && fat == 0) return null;
    return 4 * protein + 4 * carbs + 9 * fat;
  }

  double? _readNutriment(Map<String, dynamic>? nutriments, String key) {
    if (nutriments == null) return null;
    return parseNullableDouble(nutriments[key]);
  }

  double? _parseServingQuantity(dynamic value) {
    final parsed = parseNullableDouble(value);
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  double? _parseServingSize(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    // Prefer a number directly attached to a gram/millilitre unit (e.g. the
    // "215" in "1 burger (215 g)"); only fall back to the first number when no
    // unit-qualified value is present.
    final unitMatch = RegExp(
      r'([\d.,]+)\s*(?:g|ml)\b',
      caseSensitive: false,
    ).firstMatch(trimmed);
    final match = unitMatch ?? RegExp(r'([\d.,]+)').firstMatch(trimmed);
    if (match == null) return null;
    final number = match.group(1)?.replaceAll(',', '.');
    if (number == null) return null;
    return double.tryParse(number);
  }
}
