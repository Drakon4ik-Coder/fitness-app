import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/widgets/amount_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Stepper and unit switching on the amount sheet (KAN-131).

FoodItem _food({double? piece, double? serving}) => FoodItem(
  source: offSource,
  externalId: 'x',
  name: 'Egg',
  brands: '',
  rawSourceJson: '{}',
  kcal100g: 143,
  gramsPerPiece: piece,
  pieceUnit: piece == null ? null : 'egg',
  servingSizeG: serving,
);

Future<void> _pump(WidgetTester tester, FoodItem item) async {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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

String _amount(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  testWidgets('the stepper moves by one piece and never drops below one', (
    tester,
  ) async {
    await _pump(tester, _food(piece: 50));
    expect(_amount(tester), '2');

    await tester.tap(find.byTooltip('Increase'));
    await tester.pump();
    expect(_amount(tester), '3');

    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byTooltip('Decrease'));
      await tester.pump();
    }
    expect(_amount(tester), '1');
  });

  testWidgets('switching to grams keeps the amount and steps by 10 g', (
    tester,
  ) async {
    await _pump(tester, _food(piece: 50));
    await tester.tap(find.text('Grams'));
    await tester.pumpAndSettle();

    expect(_amount(tester), '100');
    expect(find.textContaining('≈ 2 eggs'), findsOneWidget);

    await tester.tap(find.byTooltip('Increase'));
    await tester.pump();
    expect(_amount(tester), '110');

    await tester.tap(find.text('Eggs'));
    await tester.pumpAndSettle();
    expect(_amount(tester), '2.2');
  });

  testWidgets('in grams, a serving-only food shows its serving equivalent', (
    tester,
  ) async {
    await _pump(tester, _food(serving: 40));
    expect(_amount(tester), '2.5');

    await tester.tap(find.text('Grams'));
    await tester.pumpAndSettle();
    expect(find.textContaining('≈ 2.5 servings'), findsOneWidget);
  });
}
