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
  });
}
