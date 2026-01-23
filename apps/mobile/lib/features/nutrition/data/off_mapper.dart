import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'food_models.dart';

class _OffImageSelection {
  const _OffImageSelection({
    required this.largeUrl,
    required this.smallUrl,
    required this.signature,
  });

  final String? largeUrl;
  final String? smallUrl;
  final String? signature;

  bool get isComplete =>
      largeUrl != null &&
      largeUrl!.isNotEmpty &&
      smallUrl != null &&
      smallUrl!.isNotEmpty;
}

class OffMapper {
  FoodItem mapProduct({
    required Map<String, dynamic> product,
    required String rawJson,
    String? localeLanguage,
  }) {
    final barcode = product['code']?.toString();
    final name = _bestName(product);
    final brands = _stringValue(product['brands']) ?? '';
    final locale = localeLanguage?.trim().toLowerCase();
    final selection = _selectImages(product, locale);
    final imageUrl = selection.smallUrl ?? selection.largeUrl;

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
    final servingSize = _parseServingSize(product['serving_size']);
    final imageSignature = selection.signature;
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
      imageUrl: imageUrl != null && imageUrl.isNotEmpty ? imageUrl : null,
      offImageLargeUrl:
          selection.largeUrl != null && selection.largeUrl!.isNotEmpty
              ? selection.largeUrl
              : null,
      offImageSmallUrl:
          selection.smallUrl != null && selection.smallUrl!.isNotEmpty
              ? selection.smallUrl
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

  _OffImageSelection _selectImages(
    Map<String, dynamic> product,
    String? locale,
  ) {
    final selected = _selectFromSelectedImages(product, locale);
    if (selected != null && selected.isComplete) {
      return selected;
    }

    final direct = _selectFromDirectFields(product);
    final computed = _selectFromImages(product, locale);

    final largeUrl = direct.largeUrl ?? computed?.largeUrl;
    final smallUrl = direct.smallUrl ?? computed?.smallUrl;
    final signature =
        computed?.signature ?? direct.signature ?? _signatureFromUrl(largeUrl ?? smallUrl);

    return _OffImageSelection(
      largeUrl: largeUrl,
      smallUrl: smallUrl,
      signature: signature,
    );
  }

  _OffImageSelection? _selectFromSelectedImages(
    Map<String, dynamic> product,
    String? locale,
  ) {
    final selectedImages = _asMap(product['selected_images']);
    if (selectedImages == null) {
      return null;
    }
    final front = _asMap(selectedImages['front']);
    if (front == null) {
      return null;
    }
    final display = _asMap(front['display']);
    final thumb = _asMap(front['thumb']);
    if (display == null || thumb == null) {
      return null;
    }
    final lang = _pickLanguage(display, thumb, locale);
    if (lang == null) {
      return null;
    }
    final largeUrl = _stringValue(display[lang]);
    final smallUrl = _stringValue(thumb[lang]);
    if (largeUrl == null || smallUrl == null) {
      return null;
    }
    final imageKey = 'front_$lang';
    final signature =
        _signatureFromImageKey(product, imageKey) ?? _signatureFromUrl(largeUrl);
    return _OffImageSelection(
      largeUrl: largeUrl,
      smallUrl: smallUrl,
      signature: signature,
    );
  }

  _OffImageSelection _selectFromDirectFields(Map<String, dynamic> product) {
    final largeUrl = _stringValue(product['image_front_url']) ??
        _stringValue(product['image_url']);
    final smallUrl = _stringValue(product['image_front_thumb_url']) ??
        _stringValue(product['image_thumb_url']) ??
        _stringValue(product['image_front_small_url']);
    final signature = _signatureFromUrl(largeUrl ?? smallUrl);
    return _OffImageSelection(
      largeUrl: largeUrl,
      smallUrl: smallUrl,
      signature: signature,
    );
  }

  _OffImageSelection? _selectFromImages(
    Map<String, dynamic> product,
    String? locale,
  ) {
    final images = _asMap(product['images']);
    if (images == null || images.isEmpty) {
      return null;
    }
    final barcode = product['code']?.toString();
    if (barcode == null || barcode.trim().isEmpty) {
      return null;
    }
    final basePath = _imageBasePath(barcode.trim());
    final candidates = _imageKeyCandidates(images, locale);

    for (final key in candidates) {
      if (!images.containsKey(key)) {
        continue;
      }
      final imageData = images[key];
      final largeFilename = _buildImageFilename(imageData, key, 400);
      final smallFilename = _buildImageFilename(imageData, key, 100);
      if (largeFilename == null || smallFilename == null) {
        continue;
      }
      final largeUrl =
          'https://images.openfoodfacts.org/images/products/$basePath/$largeFilename';
      final smallUrl =
          'https://images.openfoodfacts.org/images/products/$basePath/$smallFilename';
      final signature =
          _signatureFromImageKey(product, key) ?? _signatureFromUrl(largeUrl);
      return _OffImageSelection(
        largeUrl: largeUrl,
        smallUrl: smallUrl,
        signature: signature,
      );
    }

    return null;
  }

  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    return null;
  }

  String? _stringValue(dynamic value) {
    if (value is! String) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? _pickLanguage(
    Map<String, dynamic> display,
    Map<String, dynamic> thumb,
    String? locale,
  ) {
    final available = <String, String>{};
    for (final entry in display.entries) {
      final key = entry.key;
      if (thumb.containsKey(key)) {
        available[key.toLowerCase()] = key;
      }
    }
    if (available.isEmpty) {
      return null;
    }
    final normalizedLocale = locale?.toLowerCase();
    if (normalizedLocale != null && available.containsKey(normalizedLocale)) {
      return available[normalizedLocale];
    }
    if (available.containsKey('en')) {
      return available['en'];
    }
    return available.values.first;
  }

  List<String> _imageKeyCandidates(
    Map<String, dynamic> images,
    String? locale,
  ) {
    final keys = <String>[];
    final seen = <String>{};
    void addKey(String key) {
      if (seen.contains(key)) {
        return;
      }
      seen.add(key);
      keys.add(key);
    }

    if (locale != null && locale.isNotEmpty) {
      addKey('front_$locale');
    }
    addKey('front_en');
    final frontKeys = images.keys
        .whereType<String>()
        .where((key) => key.startsWith('front_'))
        .toList()
      ..sort();
    for (final key in frontKeys) {
      addKey(key);
    }
    if (images.containsKey('front')) {
      addKey('front');
    }
    addKey('1');
    final numericKeys = images.keys
        .whereType<String>()
        .where((key) => RegExp(r'^\d+$').hasMatch(key))
        .toList()
      ..sort((a, b) => int.parse(a).compareTo(int.parse(b)));
    for (final key in numericKeys) {
      addKey(key);
    }
    return keys;
  }

  String? _buildImageFilename(dynamic imageData, String key, int resolution) {
    if (RegExp(r'^\d+$').hasMatch(key)) {
      return '$key.$resolution.jpg';
    }
    final imageMap = _asMap(imageData);
    if (imageMap == null) {
      return null;
    }
    final rev = imageMap['rev'];
    if (rev == null) {
      return null;
    }
    return '$key.${rev.toString()}.$resolution.jpg';
  }

  String _imageBasePath(String barcode) {
    final digits = barcode.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) {
      return barcode;
    }
    final padded = digits.padLeft(13, '0');
    final part1 = padded.substring(0, 3);
    final part2 = padded.substring(3, 6);
    final part3 = padded.substring(6, 9);
    final part4 = padded.substring(9);
    return '$part1/$part2/$part3/$part4';
  }

  String? _signatureFromImageKey(
    Map<String, dynamic> product,
    String key,
  ) {
    final images = _asMap(product['images']);
    if (images == null) {
      return null;
    }
    final imageData = _asMap(images[key]);
    if (imageData == null) {
      return null;
    }
    final rev = imageData['rev'];
    if (rev == null) {
      return null;
    }
    return '$key.${rev.toString()}';
  }

  String? _signatureFromUrl(String? url) {
    if (url == null || url.trim().isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return url;
    }
    final segments = uri.pathSegments;
    if (segments.isEmpty) {
      return url;
    }
    final filename = segments.last;
    final parts = filename.split('.');
    if (parts.length >= 4 && parts.last.toLowerCase() == 'jpg') {
      return '${parts[0]}.${parts[1]}';
    }
    if (parts.length == 3 && parts.last.toLowerCase() == 'jpg') {
      return parts[0];
    }
    if (segments.length >= 2) {
      return '${segments[segments.length - 2]}/${segments.last}';
    }
    return filename;
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
    if (value == null) {
      return '';
    }
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

  double? _parseServingSize(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is num) {
      return value.toDouble();
    }
    if (value is! String) {
      return null;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final match = RegExp(r'([\d.,]+)').firstMatch(trimmed);
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
