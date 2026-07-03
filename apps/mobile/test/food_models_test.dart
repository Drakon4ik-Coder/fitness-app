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
