import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/nutrient_catalog.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/nutrition_detail_page.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';

FoodItem _food(Map<String, dynamic>? nutriments) => FoodItem(
  source: offSource,
  externalId: 'x',
  name: 'Test food',
  brands: '',
  rawSourceJson: '{}',
  nutrimentsJson: nutriments,
);

NutritionEntry _entry({
  required double quantityG,
  Map<String, dynamic>? nutriments,
}) => NutritionEntry(
  id: 1,
  mealType: 'breakfast',
  consumedAt: DateTime(2024, 1, 1),
  quantityG: quantityG,
  kcal: 0,
  foodItem: _food(nutriments),
);

NutrientTotal _find(List<NutrientTotal> totals, String key) =>
    totals.firstWhere((t) => t.spec.key == key);

void main() {
  group('nutrientPer100g unit conversion', () {
    test('converts the raw unit into the catalog unit', () {
      // Vitamin C catalog unit is mg; OFF here reports mg directly.
      final specC = kNutrientCatalog.firstWhere((s) => s.key == 'vitamin_c');
      final mg = nutrientPer100g(specC, {
        'vitamin-c_100g': 60,
        'vitamin-c_unit': 'mg',
      });
      expect(mg, closeTo(60, 1e-9));
    });

    test('converts grams source into a mg catalog unit', () {
      final specSodium = kNutrientCatalog.firstWhere((s) => s.key == 'sodium');
      // 1 g of sodium == 1000 mg (catalog unit for sodium is mg).
      final value = nutrientPer100g(specSodium, {
        'sodium_100g': 1,
        'sodium_unit': 'g',
      });
      expect(value, closeTo(1000, 1e-6));
    });

    test('assumes grams when the unit is missing', () {
      final specProtein = kNutrientCatalog.firstWhere(
        (s) => s.key == 'protein',
      );
      final value = nutrientPer100g(specProtein, {'proteins_100g': 12});
      expect(value, closeTo(12, 1e-9));
    });

    test('returns null for an unconvertible unit (e.g. IU)', () {
      final specA = kNutrientCatalog.firstWhere((s) => s.key == 'vitamin_a');
      final value = nutrientPer100g(specA, {
        'vitamin-a_100g': 500,
        'vitamin-a_unit': 'IU',
      });
      expect(value, isNull);
    });

    test('returns null when the nutrient is absent', () {
      final specIron = kNutrientCatalog.firstWhere((s) => s.key == 'iron');
      expect(nutrientPer100g(specIron, {'proteins_100g': 10}), isNull);
    });
  });

  group('aggregateNutrients', () {
    test('scales per-100g values by logged quantity and sums entries', () {
      final totals = aggregateNutrients([
        _entry(quantityG: 200, nutriments: {'proteins_100g': 10}), // 20 g
        _entry(quantityG: 50, nutriments: {'proteins_100g': 10}), // 5 g
      ]);
      expect(_find(totals, 'protein').amount, closeTo(25, 1e-9));
    });

    test('marks a nutrient with no contributing entry as no-data', () {
      final totals = aggregateNutrients([
        _entry(quantityG: 100, nutriments: {'proteins_100g': 10}),
      ]);
      final iron = _find(totals, 'iron');
      expect(iron.hasData, isFalse);
      expect(iron.amount, isNull);
    });

    test('flags over-limit only for cautionary nutrients', () {
      final totals = aggregateNutrients([
        // 300 g of salt-heavy food: 3 g salt total, target is 6 g -> under.
        _entry(quantityG: 100, nutriments: {'salt_100g': 8, 'salt_unit': 'g'}),
      ]);
      final salt = _find(totals, 'salt');
      expect(salt.amount, closeTo(8, 1e-9));
      expect(salt.isOverLimit, isTrue); // 8 g > 6 g target
      expect(salt.progress, 1.0); // clamped
    });

    test('handles entries with no nutriments blob', () {
      final totals = aggregateNutrients([_entry(quantityG: 100)]);
      expect(totals.every((t) => !t.hasData), isTrue);
    });
  });

  group('incomplete (floor) totals', () {
    test('flags a tracked macro reported by only some foods', () {
      final totals = aggregateNutrients([
        _entry(quantityG: 100, nutriments: {'proteins_100g': 10}),
        _entry(quantityG: 100, nutriments: {'carbohydrates_100g': 20}),
      ]);
      final protein = _find(totals, 'protein');
      expect(protein.hasData, isTrue);
      expect(protein.reportedCount, 1);
      expect(protein.totalCount, 2);
      expect(protein.isIncomplete, isTrue);
    });

    test('a fully-reported tracked macro is not incomplete', () {
      final totals = aggregateNutrients([
        _entry(quantityG: 100, nutriments: {'proteins_100g': 10}),
        _entry(quantityG: 100, nutriments: {'proteins_100g': 5}),
      ]);
      expect(_find(totals, 'protein').isIncomplete, isFalse);
    });

    test('a partially-reported micronutrient is NOT flagged (not tracked)', () {
      final totals = aggregateNutrients([
        _entry(quantityG: 100, nutriments: {'iron_100g': 5, 'iron_unit': 'mg'}),
        _entry(quantityG: 100, nutriments: {'proteins_100g': 10}),
      ]);
      final iron = _find(totals, 'iron');
      expect(iron.hasData, isTrue);
      expect(iron.reportedCount, 1);
      expect(iron.isIncomplete, isFalse);
    });

    test(
      'server counts drive incompleteness; absent counts read as complete',
      () {
        final incomplete = nutrientTotalsFromServer({
          'protein': {
            'amount': 10.0,
            'unit': 'g',
            'group': 'macros',
            'reported': 1,
            'total': 2,
          },
        });
        expect(_find(incomplete, 'protein').isIncomplete, isTrue);

        final legacy = nutrientTotalsFromServer({
          'protein': {'amount': 10.0, 'unit': 'g', 'group': 'macros'},
        });
        expect(_find(legacy, 'protein').isIncomplete, isFalse);
      },
    );
  });

  group('nutrientTotalsFromServer', () {
    test('reads amounts directly and marks omitted keys as no-data', () {
      final totals = nutrientTotalsFromServer({
        'protein': {'amount': 25.0, 'unit': 'g', 'group': 'macros'},
        'vitamin_c': {'amount': 60.0, 'unit': 'mg', 'group': 'vitamins'},
      });
      expect(_find(totals, 'protein').amount, closeTo(25, 1e-9));
      expect(_find(totals, 'vitamin_c').amount, closeTo(60, 1e-9));
      expect(_find(totals, 'iron').hasData, isFalse);
    });
  });

  testWidgets('detail page prefers the server nutrients map', (tester) async {
    // Iron lives in the Minerals section, far down the lazy ListView — give the
    // surface enough height that every row builds.
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: NutritionDetailPage(
          dateLabel: 'Today',
          eatenKcal: 400,
          // Entries would aggregate to nothing; the server map must win.
          entries: [_entry(quantityG: 100)],
          serverNutrients: const {
            'iron': {'amount': 9.0, 'unit': 'mg', 'group': 'minerals'},
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Iron'), findsOneWidget);
    expect(find.textContaining('9 / 18 mg'), findsOneWidget);
  });

  testWidgets('detail page renders values and no-data rows', (tester) async {
    final entries = [
      _entry(
        quantityG: 100,
        nutriments: {
          'proteins_100g': 20,
          'vitamin-c_100g': 40,
          'vitamin-c_unit': 'mg',
        },
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: NutritionDetailPage(
          dateLabel: 'Today',
          eatenKcal: 500,
          entries: entries,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Protein'), findsOneWidget);
    expect(find.text('Vitamin C'), findsOneWidget);
    // A catalog nutrient with no source data shows an explicit no-data row.
    expect(find.text('— no data'), findsWidgets);
    expect(find.text('500'), findsOneWidget); // energy header
  });

  testWidgets('tapping a nutrient row opens its top-sources sheet', (
    tester,
  ) async {
    final entries = [
      _entry(
        quantityG: 100,
        nutriments: {'vitamin-c_100g': 40, 'vitamin-c_unit': 'mg'},
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: NutritionDetailPage(
          dateLabel: 'Today',
          eatenKcal: 500,
          entries: entries,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Vitamin C'));
    await tester.pumpAndSettle();

    // The contributor sheet is up, ranking the single logged food.
    expect(find.text('TOP SOURCES'), findsOneWidget);
    expect(find.text('Test food'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget); // sole contributor's share
  });

  testWidgets('no-data nutrient rows are not tappable', (tester) async {
    final entries = [
      _entry(
        quantityG: 100,
        nutriments: {'vitamin-c_100g': 40, 'vitamin-c_unit': 'mg'},
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: NutritionDetailPage(
          dateLabel: 'Today',
          eatenKcal: 500,
          entries: entries,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Protein has no data here (top of the list, on-screen); tapping its
    // no-data row must not open a sheet.
    expect(find.text('— no data'), findsWidgets);
    await tester.tap(find.text('Protein'));
    await tester.pumpAndSettle();
    expect(find.text('TOP SOURCES'), findsNothing);
  });

  testWidgets('detail page shows empty state with no entries', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: const NutritionDetailPage(
          dateLabel: 'Today',
          eatenKcal: 0,
          entries: [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No foods logged yet'), findsOneWidget);
  });

  group('nutrientContributors', () {
    NutritionEntry namedEntry({
      required String name,
      required String brand,
      required double quantityG,
      Map<String, dynamic>? nutriments,
    }) => NutritionEntry(
      id: 1,
      mealType: 'breakfast',
      consumedAt: DateTime(2024, 1, 1),
      quantityG: quantityG,
      kcal: 0,
      foodItem: FoodItem(
        source: offSource,
        externalId: name,
        name: name,
        brands: brand,
        rawSourceJson: '{}',
        nutrimentsJson: nutriments,
      ),
    );

    final specC = kNutrientCatalog.firstWhere((s) => s.key == 'vitamin_c');

    test('ranks foods high→low with correct amounts, shares and total', () {
      final breakdown = nutrientContributors([
        // 50 g * 20 mg/100g = 10 mg
        namedEntry(
          name: 'Kiwi',
          brand: 'Fresh',
          quantityG: 50,
          nutriments: {'vitamin-c_100g': 20, 'vitamin-c_unit': 'mg'},
        ),
        // 100 g * 90 mg/100g = 90 mg (the top source)
        namedEntry(
          name: 'Orange',
          brand: '',
          quantityG: 100,
          nutriments: {'vitamin-c_100g': 90, 'vitamin-c_unit': 'mg'},
        ),
      ], specC);

      expect(breakdown.total, closeTo(100, 1e-9));
      expect(breakdown.entryCount, 2);
      expect(breakdown.missingCount, 0);
      expect(breakdown.contributors.map((c) => c.name), ['Orange', 'Kiwi']);
      expect(breakdown.contributors.first.amount, closeTo(90, 1e-9));
      expect(breakdown.contributors.first.share, closeTo(0.9, 1e-9));
      expect(breakdown.contributors.last.share, closeTo(0.1, 1e-9));
    });

    test(
      'drops foods with no data or a zero value, counting them as missing',
      () {
        final breakdown = nutrientContributors([
          namedEntry(
            name: 'Orange',
            brand: '',
            quantityG: 100,
            nutriments: {'vitamin-c_100g': 50, 'vitamin-c_unit': 'mg'},
          ),
          // Reports the nutrient but as a literal 0 — doesn't move the total.
          namedEntry(
            name: 'Water',
            brand: '',
            quantityG: 250,
            nutriments: {'vitamin-c_100g': 0, 'vitamin-c_unit': 'mg'},
          ),
          // No blob at all.
          namedEntry(name: 'Mystery', brand: '', quantityG: 100),
        ], specC);

        expect(breakdown.contributors.map((c) => c.name), ['Orange']);
        expect(breakdown.entryCount, 3);
        expect(breakdown.missingCount, 2);
      },
    );

    test('returns an empty breakdown when nothing carries the nutrient', () {
      final breakdown = nutrientContributors([
        namedEntry(name: 'Mystery', brand: '', quantityG: 100),
      ], specC);

      expect(breakdown.contributors, isEmpty);
      expect(breakdown.total, 0);
      expect(breakdown.missingCount, 1);
    });
  });
}
