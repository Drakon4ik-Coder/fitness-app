import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/widgets/amount_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FoodItem _eggs({double? gramsPerPiece, String? pieceUnit}) => FoodItem(
  source: offSource,
  externalId: 'eggs',
  name: 'Eggs',
  brands: '',
  rawSourceJson: '{}',
  kcal100g: 143,
  proteinG100g: 12,
  carbsG100g: 1,
  fatG100g: 10,
  gramsPerPiece: gramsPerPiece,
  pieceUnit: pieceUnit,
);

Future<void> _pumpSheet(
  WidgetTester tester, {
  required FoodItem item,
  required Future<FoodItem?> Function(FoodItem item) onViewDetails,
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
          onViewDetails: onViewDetails,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'unit falls back to grams when a detail edit strips piece data',
    (tester) async {
      // A piece-based food (2 × 50 g eggs)…
      await _pumpSheet(
        tester,
        item: _eggs(gramsPerPiece: 50, pieceUnit: 'egg'),
        // …whose detail edit returns an override without piece metadata,
        // exactly what the custom-food editor produces.
        onViewDetails: (_) async => _eggs(),
      );
      expect(find.text('2'), findsOneWidget);
      expect(find.textContaining('eggs'), findsOneWidget);

      // The chevron only renders inside the tappable view-details header.
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      // No dangling pieces unit: the toggle disappears (grams only) and the
      // amount re-anchors to the same 100 g rather than crashing.
      expect(tester.takeException(), isNull);
      expect(find.byType(SegmentedButton<AmountUnit>), findsNothing);
      expect(find.text('100'), findsOneWidget);
      expect(find.textContaining('grams'), findsOneWidget);
    },
  );

  testWidgets('unit survives a detail edit that keeps piece data', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      item: _eggs(gramsPerPiece: 50, pieceUnit: 'egg'),
      onViewDetails: (_) async => _eggs(gramsPerPiece: 50, pieceUnit: 'egg'),
    );

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('2'), findsOneWidget);
    expect(find.textContaining('eggs'), findsOneWidget);
  });
}
