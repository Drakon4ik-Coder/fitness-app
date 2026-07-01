import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/widgets/amount_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';

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

Future<void> _pumpSheet(WidgetTester tester, FoodItem item) async {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: LuminaHealthTheme.dark(),
      home: Scaffold(
        body: AmountSheet(item: item, initialGrams: 100, isEditing: false),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('amount sheet reveals the scaled nutrient breakdown on demand',
      (tester) async {
    await _pumpSheet(
      tester,
      _food(nutriments: {
        'proteins_100g': 1,
        'vitamin-c_100g': 50,
        'vitamin-c_unit': 'mg',
      }),
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

  testWidgets('no disclosure when the food carries no nutrient detail',
      (tester) async {
    await _pumpSheet(tester, _food(nutriments: null));
    expect(find.text('View nutrition facts'), findsNothing);
  });
}
