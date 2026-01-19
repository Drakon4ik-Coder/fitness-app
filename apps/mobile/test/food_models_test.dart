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
}
