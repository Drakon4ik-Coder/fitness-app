import 'package:fitness_app/features/nutrition/data/food_local_db.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:flutter_test/flutter_test.dart';

FoodItem _fatsecretFood({
  double? gramsPerPiece,
  String? pieceUnit,
  double? servingSizeG,
  String rawSourceJson = '{"food": {}}',
}) {
  return FoodItem(
    source: fatsecretSource,
    externalId: '12345',
    name: 'Hamburger',
    brands: '',
    kcal100g: 254,
    proteinG100g: 13,
    carbsG100g: 24,
    fatG100g: 12,
    servingSizeG: servingSizeG,
    gramsPerPiece: gramsPerPiece,
    pieceUnit: pieceUnit,
    rawSourceJson: rawSourceJson,
  );
}

void main() {
  final db = FoodLocalDb();

  test('merge keeps incoming piece fields over a piece-less local row', () {
    // Regression: a row logged before piece support (or from a search stub)
    // has null piece columns; the enriched detail fetch must win or the
    // burger/cookie quantity default vanishes on every local reload.
    final existing = _fatsecretFood(servingSizeG: 100);
    final incoming = _fatsecretFood(
      gramsPerPiece: 110,
      pieceUnit: 'burger',
      servingSizeG: 110,
      rawSourceJson: '{"food": {}, "serving_size": "1 burger (110 g)"}',
    );

    final merged = db.mergeFood(existing, incoming);

    expect(merged.gramsPerPiece, 110);
    expect(merged.pieceUnit, 'burger');
    expect(merged.servingSizeG, 110);
  });

  test('merge keeps existing piece fields when the incoming item has none', () {
    // Same "incoming null means not fetched" contract as the other nutrition
    // fields: a piece-less search stub must not erase enriched piece data.
    final existing = _fatsecretFood(
      gramsPerPiece: 110,
      pieceUnit: 'burger',
      servingSizeG: 110,
    );
    final incoming = _fatsecretFood(servingSizeG: 100);

    final merged = db.mergeFood(existing, incoming);

    expect(merged.gramsPerPiece, 110);
    expect(merged.pieceUnit, 'burger');
  });
}
