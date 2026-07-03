import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/data/food_models.dart';

void main() {
  test('toBackendPayload falls back on invalid raw_source_json', () {
    final item = FoodItem(
      source: offSource,
      externalId: '123',
      name: 'Test Food',
      brands: 'Test Brand',
      rawSourceJson: '{invalid',
    );

    final payload = item.toBackendPayload();
    final raw = payload['raw_source_json'];

    expect(raw, isA<Map<String, dynamic>>());
    expect((raw as Map<String, dynamic>).isEmpty, isTrue);
  });

  test('fromDbMap returns null nutrimentsJson for invalid nutriments_json', () {
    final item = FoodItem.fromDbMap(<String, Object?>{
      'nutriments_json': '{invalid',
      'raw_source_json': '{}',
    });

    expect(item.nutrimentsJson, isNull);
  });

  group('detectCookedNutritionBasis', () {
    test('flags fresh meat with protein above the raw ceiling', () {
      // UK mince case: 29 g protein/100g is only reachable after cooking.
      expect(
        detectCookedNutritionBasis(
          categoriesTags: const ['en:meats', 'en:beef', 'en:beef-steaks'],
          proteinG100g: 29,
        ),
        isTrue,
      );
    });

    test('does not flag raw meat with a plausible raw protein', () {
      expect(
        detectCookedNutritionBasis(
          categoriesTags: const ['en:meats', 'en:chicken'],
          proteinG100g: 22,
        ),
        isFalse,
      );
    });

    test('does not flag protein-dense cured/prepared meat', () {
      // Cured ham is legitimately ~30 g protein as sold.
      expect(
        detectCookedNutritionBasis(
          categoriesTags: const ['en:meats', 'en:prepared-meats', 'en:hams'],
          proteinG100g: 30,
        ),
        isFalse,
      );
    });

    test('does not flag protein-dense non-meat foods', () {
      expect(
        detectCookedNutritionBasis(
          categoriesTags: const ['en:dairies', 'en:cheeses'],
          proteinG100g: 28,
        ),
        isFalse,
      );
    });

    test('does not flag when protein is unknown', () {
      expect(
        detectCookedNutritionBasis(
          categoriesTags: const ['en:meats', 'en:beef'],
          proteinG100g: null,
        ),
        isFalse,
      );
    });

    group('CIQUAL raw-reference cross-check', () {
      test('flags protein far above the raw reference, no categories needed',
          () {
        // CIQUAL 6250 "Beef, minced steak, 5% fat, raw" = 21.9 g protein;
        // the label's 29 g is the grilled column (ratio 1.32).
        expect(
          detectCookedNutritionBasis(
            categoriesTags: const [],
            proteinG100g: 29,
            ciqualCode: 6250,
          ),
          isTrue,
        );
      });

      test('catches cooked values the raw ceiling alone would miss', () {
        // Cooked 20% mince is ~24 g protein — under the 25 g ceiling — but
        // 1.39x the 17.3 g raw reference (CIQUAL 6256).
        expect(
          detectCookedNutritionBasis(
            categoriesTags: const ['en:meats', 'en:beef'],
            proteinG100g: 24,
            ciqualCode: 6256,
          ),
          isTrue,
        );
      });

      test('a raw reference match near the label suppresses the ceiling rule',
          () {
        // 26 g protein would trip the category ceiling, but it is only 1.19x
        // the raw reference — plausibly raw, so the reference wins.
        expect(
          detectCookedNutritionBasis(
            categoriesTags: const ['en:meats', 'en:beef'],
            proteinG100g: 26,
            ciqualCode: 6250,
          ),
          isFalse,
        );
      });

      test('an unknown code falls back to the category heuristic', () {
        expect(
          detectCookedNutritionBasis(
            categoriesTags: const ['en:meats', 'en:beef'],
            proteinG100g: 29,
            ciqualCode: 999999,
          ),
          isTrue,
        );
      });
    });
  });

  test('fromBackendDetail re-derives the cooked basis from raw categories',
      () {
    final item = FoodItem.fromBackendDetail(<String, dynamic>{
      'id': 7,
      'name': 'Lean Beef Steak Mince',
      'protein_g_100g': 29,
      'raw_source_json':
          '{"product": {"categories_tags": ["en:meats", "en:beef"]}}',
    });

    expect(item.isCookedBasis, isTrue);
  });

  test('fromBackendDetail re-derives the cooked basis from the CIQUAL match',
      () {
    // No category tags needed: the round-tripped Agribalyse block alone
    // identifies the raw reference food.
    final item = FoodItem.fromBackendDetail(<String, dynamic>{
      'id': 7,
      'name': 'Lean Beef Steak Mince',
      'protein_g_100g': 29,
      'raw_source_json': '{"product": {"ecoscore_data": {"agribalyse": '
          '{"agribalyse_food_code": "6250"}}}}',
    });

    expect(item.isCookedBasis, isTrue);
  });

  test('fromBackendSummary keeps the custom source and external id', () {
    final item = FoodItem.fromBackendSummary(<String, dynamic>{
      'id': 12,
      'source': 'custom',
      'external_id': 'cf-abc',
      'name': "Mum's granola",
      'barcode': null,
    });

    expect(item.isCustom, isTrue);
    expect(item.externalId, 'cf-abc');
    expect(item.backendId, 12);
  });

  test('nutrition basis round-trips through the local db map', () {
    final item = FoodItem(
      source: offSource,
      externalId: '123',
      name: 'Mince',
      brands: '',
      rawSourceJson: '{}',
      nutritionBasis: cookedNutritionBasis,
    );

    final restored = FoodItem.fromDbMap(item.toDbMap());
    expect(restored.isCookedBasis, isTrue);
  });
}
