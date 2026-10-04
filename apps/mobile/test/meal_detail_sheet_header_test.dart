/// The meal sheet header must show the full meal name at a common phone width
/// with both header actions present: the kcal total once shared the row as a
/// second flex child and ellipsized "Breakfast" to "Breakfa…" at 390pt.
library;

import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/widgets/meal_detail_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

NutritionEntry _entry(int id, String name, double kcal) => NutritionEntry(
  id: id,
  uuid: 'uuid-$id',
  mealType: 'breakfast',
  consumedAt: DateTime.utc(2024, 1, 1, 8),
  quantityG: 100,
  kcal: kcal,
  foodItem: FoodItem(
    source: offSource,
    externalId: 'x-$name',
    name: name,
    brands: '',
    rawSourceJson: '{}',
    kcal100g: kcal,
  ),
);

/// A 390x844 logical phone (iPhone 12–15 class) at 2x density.
void _phoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpSheet(WidgetTester tester, String mealLabel) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: LuminaHealthTheme.dark(),
      home: Scaffold(
        body: MealDetailSheet(
          mealLabel: mealLabel,
          mealTypeName: mealLabel.toLowerCase(),
          mealIcon: Icons.breakfast_dining,
          mealColor: LuminaHealthColors.tertiary,
          entries: [_entry(1, 'Rolled oats', 303), _entry(2, 'Banana', 107)],
          onUpdateEntry: (entry, {quantityG, mealType}) async => entry,
          onDeleteEntry: (_) async => true,
          onRestoreEntry: (entry) async => entry,
          onAddMore: () {},
          onDuplicate: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final label in ['Breakfast', 'Lunch', 'Dinner', 'Snacks']) {
    testWidgets('"$label" is not truncated at 390pt with both actions', (
      tester,
    ) async {
      _phoneSurface(tester);
      await _pumpSheet(tester, label);

      expect(find.byKey(const Key('duplicateMeal')), findsOneWidget);
      expect(find.byTooltip('Move all to another meal'), findsOneWidget);
      expect(find.text('410'), findsOneWidget);

      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.text(label), matching: find.byType(RichText)),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
    });
  }

  testWidgets('header lays out without overflow at 2x text scale', (
    tester,
  ) async {
    _phoneSurface(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    await _pumpSheet(tester, 'Breakfast');

    // Any RenderFlex overflow is reported as a FlutterError and fails here.
    expect(tester.takeException(), isNull);
    expect(find.text('Breakfast'), findsOneWidget);
    expect(find.text('410'), findsOneWidget);
    expect(find.byKey(const Key('duplicateMeal')), findsOneWidget);
    expect(find.byTooltip('Move all to another meal'), findsOneWidget);
  });
}
