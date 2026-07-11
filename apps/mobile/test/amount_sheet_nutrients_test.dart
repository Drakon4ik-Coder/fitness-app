import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/nutrient_catalog.dart';
import 'package:fitness_app/features/nutrition/widgets/amount_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FoodItem _food({Map<String, dynamic>? nutriments}) => FoodItem(
  source: offSource,
  externalId: 'x',
  name: 'Orange juice',
  brands: '',
  rawSourceJson: '{}',
  kcal100g: 45,
  proteinG100g: 1,
  carbsG100g: 10,
  fatG100g: 0,
  nutrimentsJson: nutriments,
);

Future<void> _pumpSheet(
  WidgetTester tester,
  FoodItem item, {
  List<NutrientSpec>? focusSpecs,
}) async {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: LuminaHealthTheme.dark(),
      home: Scaffold(
        body: AmountSheet(
          item: item,
          initialGrams: 100,
          isEditing: false,
          focusSpecs: focusSpecs,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('amount sheet reveals the scaled nutrient breakdown on demand', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      _food(
        nutriments: {
          'proteins_100g': 1,
          'vitamin-c_100g': 50,
          'vitamin-c_unit': 'mg',
        },
      ),
    );

    // Collapsed by default — vitamins not shown, just the disclosure toggle.
    expect(find.text('View nutrition facts'), findsOneWidget);
    expect(find.text('Vitamin C'), findsNothing);

    await tester.tap(find.text('View nutrition facts'));
    await tester.pumpAndSettle();

    expect(find.text('Hide nutrition facts'), findsOneWidget);
    expect(find.text('Vitamin C'), findsOneWidget);
    // 100 g * 50 mg/100g = 50 mg against an 80 mg target.
    expect(find.textContaining('50 / 80 mg'), findsOneWidget);
  });

  testWidgets('no disclosure when the food carries no nutrient detail', (
    tester,
  ) async {
    // Neither a nutriments blob nor flat macro columns — nothing to disclose.
    final barren = FoodItem(
      source: offSource,
      externalId: 'x',
      name: 'Mystery food',
      brands: '',
      rawSourceJson: '{}',
      kcal100g: 45,
    );
    await _pumpSheet(tester, barren);
    expect(find.text('View nutrition facts'), findsNothing);
  });

  testWidgets('flat macro columns alone still offer the nutrition facts', (
    tester,
  ) async {
    // No blob, but the flat per-100g columns carry data (older local rows,
    // search results) — the breakdown must not read as empty.
    await _pumpSheet(tester, _food(nutriments: null));

    await tester.tap(find.text('View nutrition facts'));
    await tester.pumpAndSettle();

    // 100 g of the 10 g/100g flat carbs column against the 260 g target.
    expect(find.text('Carbs'), findsOneWidget);
    expect(find.textContaining('10 / 260 g'), findsOneWidget);
  });

  testWidgets('preview pills default to the macro trio from column data', (
    tester,
  ) async {
    // No nutriments blob — the classic macros fall back to the flat columns.
    await _pumpSheet(tester, _food(nutriments: null));

    expect(find.text('P'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    expect(find.text('F'), findsOneWidget);
    // 100 g of 1 / 10 / 0 per-100g.
    expect(find.text('1g'), findsOneWidget);
    expect(find.text('10g'), findsOneWidget);
    expect(find.text('0g'), findsOneWidget);
  });

  testWidgets('preview pills follow the provided focus nutrients', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      _food(nutriments: {'fiber_100g': 5, 'sodium_100g': 0.4}),
      focusSpecs: resolveFocusSpecs(const ['fiber', 'sodium', 'vitamin_c']),
    );

    // Fiber: 5 g. Sodium: 0.4 g (grams assumed) -> 400 mg, in its own unit.
    expect(find.text('Fib'), findsOneWidget);
    expect(find.text('5g'), findsOneWidget);
    expect(find.text('Na'), findsOneWidget);
    expect(find.text('400 mg'), findsOneWidget);
    // Vitamin C has no data for this food -> dash, not a misleading 0.
    expect(find.text('Vit C'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    // The default trio is replaced.
    expect(find.text('P'), findsNothing);
  });
}
