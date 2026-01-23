import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/data/off_mapper.dart';

void main() {
  test('maps OFF product to normalized fields with kcal fallback', () {
    final mapper = OffMapper();
    final product = {
      'code': '123456',
      'product_name': 'Test Bar',
      'brands': 'Test Brand',
      'serving_size': '30 g',
      'nutriments': {
        'proteins_100g': 10,
        'carbohydrates_100g': 20,
        'fat_100g': 5,
        'sugars_100g': 2,
        'fiber_100g': 3,
        'salt_100g': 0.5,
      },
    };

    final item = mapper.mapProduct(
      product: product,
      rawJson: '{"product": {"product_name": "Test Bar"}}',
    );

    expect(item.name, 'Test Bar');
    expect(item.brands, 'Test Brand');
    expect(item.servingSizeG, 30);
    expect(item.kcal100g, 165);
    expect(item.proteinG100g, 10);
    expect(item.carbsG100g, 20);
    expect(item.fatG100g, 5);
    expect(item.sugarsG100g, 2);
    expect(item.fiberG100g, 3);
    expect(item.saltG100g, 0.5);
    expect(item.nutrimentsJson, isNotNull);
    expect(item.contentHash, isNotEmpty);
  });

  test('prefers selected_images front display/thumb by locale', () {
    final mapper = OffMapper();
    final product = {
      'code': '1234567890123',
      'product_name': 'Test Bar',
      'brands': 'Test Brand',
      'selected_images': {
        'front': {
          'display': {
            'fr':
                'https://images.openfoodfacts.org/images/products/123/456/789/0123/front_fr.11.400.jpg',
            'en':
                'https://images.openfoodfacts.org/images/products/123/456/789/0123/front_en.5.400.jpg',
          },
          'thumb': {
            'fr':
                'https://images.openfoodfacts.org/images/products/123/456/789/0123/front_fr.11.100.jpg',
            'en':
                'https://images.openfoodfacts.org/images/products/123/456/789/0123/front_en.5.100.jpg',
          },
        },
      },
      'images': {
        'front_fr': {'rev': 11},
        'front_en': {'rev': 5},
      },
    };

    final item = mapper.mapProduct(
      product: product,
      rawJson: '{"product": {"product_name": "Test Bar"}}',
      localeLanguage: 'fr',
    );

    expect(
      item.offImageLargeUrl,
      'https://images.openfoodfacts.org/images/products/123/456/789/0123/front_fr.11.400.jpg',
    );
    expect(
      item.offImageSmallUrl,
      'https://images.openfoodfacts.org/images/products/123/456/789/0123/front_fr.11.100.jpg',
    );
    expect(item.imageSignature, 'front_fr.11');
  });

  test('falls back to image_front_url and thumb', () {
    final mapper = OffMapper();
    final product = {
      'code': '123456',
      'product_name': 'Test Bar',
      'brands': 'Test Brand',
      'image_front_url':
          'https://images.openfoodfacts.org/images/products/000/000/123/4560/front_en.2.400.jpg',
      'image_front_thumb_url':
          'https://images.openfoodfacts.org/images/products/000/000/123/4560/front_en.2.100.jpg',
    };

    final item = mapper.mapProduct(
      product: product,
      rawJson: '{"product": {"product_name": "Test Bar"}}',
    );

    expect(
      item.offImageLargeUrl,
      'https://images.openfoodfacts.org/images/products/000/000/123/4560/front_en.2.400.jpg',
    );
    expect(
      item.offImageSmallUrl,
      'https://images.openfoodfacts.org/images/products/000/000/123/4560/front_en.2.100.jpg',
    );
    expect(item.imageSignature, 'front_en.2');
  });

  test('computes image URLs from images metadata when needed', () {
    final mapper = OffMapper();
    final product = {
      'code': '1234567890',
      'product_name': 'Test Bar',
      'brands': 'Test Brand',
      'images': {
        'front_en': {'rev': 3},
      },
    };

    final item = mapper.mapProduct(
      product: product,
      rawJson: '{"product": {"product_name": "Test Bar"}}',
      localeLanguage: 'en',
    );

    expect(
      item.offImageLargeUrl,
      'https://images.openfoodfacts.org/images/products/000/123/456/7890/front_en.3.400.jpg',
    );
    expect(
      item.offImageSmallUrl,
      'https://images.openfoodfacts.org/images/products/000/123/456/7890/front_en.3.100.jpg',
    );
    expect(item.imageSignature, 'front_en.3');
  });

  test('content hash changes when image signature changes', () {
    final mapper = OffMapper();
    final baseProduct = {
      'code': '1234567890',
      'product_name': 'Test Bar',
      'brands': 'Test Brand',
      'images': {
        'front_en': {'rev': 3},
      },
    };
    final updatedProduct = {
      ...baseProduct,
      'images': {
        'front_en': {'rev': 4},
      },
    };

    final original = mapper.mapProduct(
      product: baseProduct,
      rawJson: '{"product": {"product_name": "Test Bar"}}',
      localeLanguage: 'en',
    );
    final updated = mapper.mapProduct(
      product: updatedProduct,
      rawJson: '{"product": {"product_name": "Test Bar"}}',
      localeLanguage: 'en',
    );

    expect(original.contentHash, isNot(updated.contentHash));
  });

  test('parses numeric serving_size values', () {
    final mapper = OffMapper();
    final product = {
      'code': '987654',
      'product_name': 'Test Bar',
      'brands': 'Test Brand',
      'serving_size': 42,
    };

    final item = mapper.mapProduct(
      product: product,
      rawJson: '{"product": {"product_name": "Test Bar"}}',
    );

    expect(item.servingSizeG, 42);
  });

  test('handles non-string brands safely', () {
    final mapper = OffMapper();
    final product = {
      'code': '555555',
      'product_name': 'Test Bar',
      'brands': ['Brand A', 'Brand B'],
    };

    final item = mapper.mapProduct(
      product: product,
      rawJson: '{"product": {"product_name": "Test Bar"}}',
    );

    expect(item.brands, '');
  });
}
