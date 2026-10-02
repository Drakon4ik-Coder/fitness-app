import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/food_search_results.dart';
import 'package:flutter_test/flutter_test.dart';

FoodItem _food(
  String name, {
  String source = offSource,
  String? externalId,
  String? barcode,
  int? backendId,
  double? completeness,
  int? overridesBackendId,
  String? overridesBarcode,
}) {
  return FoodItem(
    source: source,
    externalId: externalId ?? 'ext-$name',
    barcode: barcode,
    backendId: backendId,
    name: name,
    brands: '',
    completeness: completeness,
    overridesBackendId: overridesBackendId,
    overridesBarcode: overridesBarcode,
    rawSourceJson: '{}',
  );
}

List<String> _names(List<FoodResult> results) => [
  for (final result in results) result.item.name,
];

void main() {
  group('foodResultKey', () {
    test('prefers barcode, then source-qualified external id, then '
        'backend id', () {
      expect(
        foodResultKey(_food('a', barcode: '123', backendId: 9)),
        'barcode:123',
      );
      expect(
        foodResultKey(_food('a', source: fatsecretSource, externalId: '42')),
        'external:fatsecret:42',
      );
      expect(
        foodResultKey(_food('a', externalId: '', backendId: 9)),
        'backend:9',
      );
      expect(foodResultKey(_food('a', externalId: '')), isNull);
    });
  });

  group('offResultsForDisplay', () {
    test('drops hits under the completeness floor', () {
      final good = _food('good', completeness: 0.8);
      final sparse = _food('sparse', completeness: 0.2);
      expect(offResultsForDisplay([good, sparse]), [good]);
    });

    test('keeps everything when no hit clears the floor', () {
      final sparse = _food('sparse', completeness: 0.2);
      final unknown = _food('unknown');
      expect(offResultsForDisplay([sparse, unknown]), [sparse, unknown]);
    });
  });

  group('nameMatchScore', () {
    test('ranks exact > prefix > word start > substring', () {
      final exact = nameMatchScore('Egg', 'egg');
      final prefix = nameMatchScore('Eggplant', 'egg');
      final word = nameMatchScore('Boiled egg', 'egg');
      final substring = nameMatchScore('Legging', 'egg');
      expect(exact, greaterThan(prefix));
      expect(prefix, greaterThan(word));
      expect(word, greaterThan(substring));
    });

    test('is zero for an empty query', () {
      expect(nameMatchScore('Anything', ''), 0);
    });
  });

  group('mergeFoodResults', () {
    test('an empty query shows the local list in order, ignoring the online '
        'sources', () {
      final results = mergeFoodResults(
        query: '  ',
        local: [_food('Zucchini'), _food('Apple')],
        backend: [_food('Banana')],
        off: [_food('Cherry')],
        fatsecret: [_food('Date')],
      );
      expect(_names(results), ['Zucchini', 'Apple']);
      expect(
        results.map((r) => r.origin),
        everyElement(FoodResultOrigin.local),
      );
    });

    test('de-duplicates across sources, keeping the first (local) copy', () {
      final results = mergeFoodResults(
        query: 'oats',
        local: [_food('Oats', barcode: '111')],
        backend: [_food('Oats backend', barcode: '111')],
        off: [_food('Oats off', barcode: '111', completeness: 1)],
        fatsecret: const [],
      );
      expect(_names(results), ['Oats']);
      expect(results.single.origin, FoodResultOrigin.local);
    });

    test('hides globals shadowed by an override, by backend id or barcode', () {
      final override = _food(
        'Milk (mine)',
        source: customSource,
        overridesBackendId: 5,
        overridesBarcode: '999',
      );
      final results = mergeFoodResults(
        query: 'milk',
        local: [override],
        backend: [_food('Milk', backendId: 5, externalId: 'g-5')],
        off: [_food('Milk OFF', barcode: '999', completeness: 1)],
        fatsecret: [_food('Milkshake', source: fatsecretSource)],
      );
      expect(_names(results), unorderedEquals(['Milk (mine)', 'Milkshake']));
    });

    test('ranks by name relevance before source and completeness', () {
      final results = mergeFoodResults(
        query: 'rice',
        local: [_food('Fried rice with egg')],
        backend: [_food('Rice')],
        off: [_food('Rice cakes', completeness: 1)],
        fatsecret: const [],
      );
      expect(_names(results), ['Rice', 'Rice cakes', 'Fried rice with egg']);
    });

    test('applies the OFF completeness floor to the merged list', () {
      final results = mergeFoodResults(
        query: 'big mac',
        local: const [],
        backend: const [],
        off: [
          _food('Big Mac', completeness: 0.9),
          _food('Big Mac miscoded', completeness: 0.1),
        ],
        fatsecret: const [],
      );
      expect(_names(results), ['Big Mac']);
    });
  });
}
