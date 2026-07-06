import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/widgets/amount_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';

// Modeled on UK lean beef mince whose label states nutrition per 100 g
// grilled: 172 kcal / 29 g protein per cooked 100 g.
FoodItem _mince({String? basis = cookedNutritionBasis}) => FoodItem(
  source: offSource,
  externalId: '5054070875254',
  name: 'Lean Beef Steak Mince',
  brands: '',
  rawSourceJson: '{}',
  kcal100g: 172,
  proteinG100g: 29,
  carbsG100g: 0,
  fatG100g: 6.3,
  nutritionBasis: basis,
);

Future<void> _pumpSheet(
  WidgetTester tester,
  FoodItem item, {
  double initialGrams = 75,
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
          initialGrams: initialGrams,
          isEditing: false,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cooked-basis food defaults to raw-weight entry', (tester) async {
    // 75 stored (cooked) grams surface as the 100 g the scale showed.
    await _pumpSheet(tester, _mince());

    expect(find.text('Raw weight'), findsOneWidget);
    expect(find.text('Cooked weight'), findsOneWidget);
    expect(find.text('172 kcal per 100g cooked'), findsOneWidget);
    expect(find.widgetWithText(TextField, '100'), findsOneWidget);
    expect(find.textContaining('≈ 75 g cooked'), findsOneWidget);
    // Preview scales by the cooked-equivalent weight: 172 × 0.75.
    expect(find.text('129'), findsOneWidget);
  });

  testWidgets('switching to cooked weight re-expresses the same amount', (
    tester,
  ) async {
    await _pumpSheet(tester, _mince());

    await tester.tap(find.text('Cooked weight'));
    await tester.pumpAndSettle();

    // Same 75 cooked grams, now shown directly; kcal unchanged.
    expect(find.widgetWithText(TextField, '75'), findsOneWidget);
    expect(find.textContaining('≈ 100 g raw'), findsOneWidget);
    expect(find.text('129'), findsOneWidget);
  });

  testWidgets('typed raw grams convert through the cooked yield', (
    tester,
  ) async {
    await _pumpSheet(tester, _mince());

    await tester.enterText(find.byType(TextField), '200');
    await tester.pumpAndSettle();

    // 200 g raw × 0.75 = 150 g cooked → 172 × 1.5 = 258 kcal.
    expect(find.textContaining('≈ 150 g cooked'), findsOneWidget);
    expect(find.text('258'), findsOneWidget);
  });

  testWidgets('as-sold foods show no raw/cooked toggle', (tester) async {
    await _pumpSheet(tester, _mince(basis: null), initialGrams: 100);

    expect(find.text('Raw weight'), findsNothing);
    expect(find.text('172 kcal per 100g'), findsOneWidget);
  });

  test(
    'describeAmount reads raw with the cooked equivalent in parentheses',
    () {
      expect(describeAmount(75, _mince()), '100 g raw (75 g cooked)');
      expect(describeAmount(100, _mince(basis: null)), '100 g');
    },
  );
}
