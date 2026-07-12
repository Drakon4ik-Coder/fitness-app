import 'package:fitness_app/features/nutrition/data/off_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('prefers most recently uploaded org- image at full resolution', () {
    final mapper = OffMapper();
    final product = {
      'code': '1234567890123',
      'product_name': 'Test Bar',
      'brands': 'Test Brand',
      'images': {
        // org- image uploaded later — should win
        '5': {
          'uploader': 'org-bestbrand',
          'uploaded_t': 1700000100,
          'sizes': {
            'full': {'h': 1200, 'w': 600},
          },
        },
        // org- image uploaded earlier — should lose
        '3': {
          'uploader': 'org-bestbrand',
          'uploaded_t': 1700000000,
          'sizes': {
            'full': {'h': 1200, 'w': 600},
          },
        },
        // non-org image — should be ignored
        '1': {
          'uploader': 'kiliweb',
          'uploaded_t': 1700000200,
          'sizes': {
            'full': {'h': 1000, 'w': 500},
          },
        },
        'front_en': {'imgid': '1', 'rev': 10},
      },
    };

    final item = mapper.mapProduct(
      product: product,
      rawJson: '{"product": {"product_name": "Test Bar"}}',
    );

    expect(
      item.imageUrl,
      'https://images.openfoodfacts.org/images/products/123/456/789/0123/5.jpg',
    );
    expect(item.imageSignature, '5');
  });

  test('falls back to selected front image at full resolution by locale', () {
    final mapper = OffMapper();
    final product = {
      'code': '1234567890123',
      'product_name': 'Test Bar',
      'brands': 'Test Brand',
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
      item.imageUrl,
      'https://images.openfoodfacts.org/images/products/123/456/789/0123/front_fr.11.full.jpg',
    );
    expect(item.imageSignature, 'front_fr.11');
  });

  test('prefers en over other langs when locale not available', () {
    final mapper = OffMapper();
    final product = {
      'code': '1234567890',
      'product_name': 'Test Bar',
      'brands': 'Test Brand',
      'images': {
        'front_de': {'rev': 2},
        'front_en': {'rev': 3},
      },
    };

    final item = mapper.mapProduct(
      product: product,
      rawJson: '{"product": {"product_name": "Test Bar"}}',
      localeLanguage: 'es',
    );

    expect(
      item.imageUrl,
      'https://images.openfoodfacts.org/images/products/000/123/456/7890/front_en.3.full.jpg',
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

  test('joins list brands from Search-a-licious into a string', () {
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

    expect(item.brands, 'Brand A, Brand B');
  });

  test('returns null imageUrl when no org or front image present', () {
    final mapper = OffMapper();
    final product = {
      'code': '123456',
      'product_name': 'Test Bar',
      'brands': 'Test Brand',
    };

    final item = mapper.mapProduct(
      product: product,
      rawJson: '{"product": {"product_name": "Test Bar"}}',
    );

    expect(item.imageUrl, isNull);
    expect(item.imageSignature, isNull);
  });

  test('derives a piece descriptor from a piece-counted serving', () {
    final mapper = OffMapper();
    final item = mapper.mapProduct(
      product: {
        'code': '111',
        'product_name': 'Eggs',
        'serving_size': '2 eggs (105 g)',
        'serving_quantity': 105,
        'nutriments': {'energy-kcal_100g': 143},
      },
      rawJson: '{"product": {"product_name": "Eggs"}}',
    );

    expect(item.servingSizeG, 105);
    expect(item.gramsPerPiece, closeTo(52.5, 0.001));
    expect(item.pieceUnit, 'egg');
  });

  test('treats a single piece as one whole unit', () {
    final mapper = OffMapper();
    final item = mapper.mapProduct(
      product: {
        'code': '222',
        'product_name': 'Big Mac',
        'serving_size': '1 burger (215 g)',
        'serving_quantity': 215,
        'nutriments': {'energy-kcal_100g': 250},
      },
      rawJson: '{"product": {"product_name": "Big Mac"}}',
    );

    expect(item.gramsPerPiece, 215);
    expect(item.pieceUnit, 'burger');
  });

  test('does not treat measure words (serving/g) as pieces', () {
    final mapper = OffMapper();
    final item = mapper.mapProduct(
      product: {
        'code': '333',
        'product_name': 'Chips',
        'serving_size': '1 serving (28 g)',
        'serving_quantity': 28,
        'nutriments': {'energy-kcal_100g': 500},
      },
      rawJson: '{"product": {"product_name": "Chips"}}',
    );

    expect(item.servingSizeG, 28);
    expect(item.gramsPerPiece, isNull);
    expect(item.pieceUnit, isNull);
  });

  test('drops an inconsistent serving via the kcal sanity guard', () {
    final mapper = OffMapper();
    // 250 kcal/100g over a 232 g serving implies ~580 kcal/serving, but the
    // serving energy says 50 — the serving is untrustworthy and is dropped.
    final item = mapper.mapProduct(
      product: {
        'code': '444',
        'product_name': 'Suspect Burger',
        'serving_size': '1 burger (232 g)',
        'serving_quantity': 232,
        'nutriments': {'energy-kcal_100g': 250, 'energy-kcal_serving': 50},
      },
      rawJson: '{"product": {"product_name": "Suspect Burger"}}',
    );

    expect(item.servingSizeG, isNull);
    expect(item.gramsPerPiece, isNull);
  });

  test('ignores a bare piece count with no weight (no 1 g/egg)', () {
    final mapper = OffMapper();
    final item = mapper.mapProduct(
      product: {
        'code': '666',
        'product_name': 'Eggs',
        'serving_size': '1 egg',
        'serving_quantity': 1,
        'nutriments': {'energy-kcal_100g': 143},
      },
      rawJson: '{"product": {"product_name": "Eggs"}}',
    );

    expect(item.servingSizeG, isNull);
    expect(item.gramsPerPiece, isNull);
    expect(item.pieceUnit, isNull);
  });

  test('does not read an mg serving as grams (no 1000x serving)', () {
    final mapper = OffMapper();
    final item = mapper.mapProduct(
      product: {
        'code': '888',
        'product_name': 'Vitamin D drops',
        'serving_size': '100 mg',
        'serving_quantity': 100,
        'serving_quantity_unit': 'mg',
        'nutriments': {'energy-kcal_100g': 400},
      },
      rawJson: '{"product": {"product_name": "Vitamin D drops"}}',
    );

    expect(item.servingSizeG, isNull);
    expect(item.gramsPerPiece, isNull);
  });

  test('reads completeness for search-result ranking', () {
    final mapper = OffMapper();
    final item = mapper.mapProduct(
      product: {
        'code': '777',
        'product_name': 'Big Mac',
        'completeness': 0.875,
        'nutriments': {'energy-kcal_100g': 228},
      },
      rawJson: '{"product": {"product_name": "Big Mac"}}',
    );

    expect(item.completeness, 0.875);
  });

  test('keeps a serving whose energy is consistent', () {
    final mapper = OffMapper();
    final item = mapper.mapProduct(
      product: {
        'code': '555',
        'product_name': 'Good Burger',
        'serving_size': '1 burger (232 g)',
        'serving_quantity': 232,
        'nutriments': {'energy-kcal_100g': 250, 'energy-kcal_serving': 580},
      },
      rawJson: '{"product": {"product_name": "Good Burger"}}',
    );

    expect(item.servingSizeG, 232);
    expect(item.gramsPerPiece, 232);
    expect(item.pieceUnit, 'burger');
  });

  test('flags fresh meat with cooked-column protein as cooked basis', () {
    final mapper = OffMapper();
    // Modeled on ASDA Lean Scotch Beef Steak Mince (5054070875254): raw 5%
    // mince is ~21 g protein/100g, so 29 g means the grilled column was
    // entered into the plain per-100g fields.
    final item = mapper.mapProduct(
      product: {
        'code': '5054070875254',
        'product_name': 'Lean Scotch Beef Steak Mince',
        'categories_tags': ['en:meats', 'en:beef', 'en:ground-beef-steaks'],
        'nutriments': {
          'energy-kcal_100g': 172,
          'proteins_100g': 29,
          'fat_100g': 6.3,
        },
      },
      rawJson: '{}',
    );

    expect(item.isCookedBasis, isTrue);
  });

  test('leaves plausibly-raw meat on the as-sold basis', () {
    final mapper = OffMapper();
    final item = mapper.mapProduct(
      product: {
        'code': '999',
        'product_name': 'Beef Mince 20% Fat',
        'categories_tags': ['en:meats', 'en:beef'],
        'nutriments': {
          'energy-kcal_100g': 254,
          'proteins_100g': 17,
          'fat_100g': 20,
        },
      },
      rawJson: '{}',
    );

    expect(item.isCookedBasis, isFalse);
  });

  test('flags cooked basis via the Agribalyse CIQUAL match alone', () {
    final mapper = OffMapper();
    // Cooked 20% mince: 24 g protein is under the raw ceiling, so only the
    // CIQUAL raw reference (6256: 17.3 g) catches it.
    final item = mapper.mapProduct(
      product: {
        'code': '888',
        'product_name': 'Beef Mince 20% Fat',
        'categories_tags': ['en:meats', 'en:beef'],
        'ecoscore_data': {
          'agribalyse': {'agribalyse_food_code': '6256'},
        },
        'nutriments': {
          'energy-kcal_100g': 270,
          'proteins_100g': 24,
          'fat_100g': 18,
        },
      },
      rawJson: '{}',
    );

    expect(item.isCookedBasis, isTrue);
  });
}
