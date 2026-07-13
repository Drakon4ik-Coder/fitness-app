/// Duplicate meal: the sheet's header action hands the entries *as currently
/// shown* (in-sheet edits and deletes included) to the parent, which stages
/// them into a fresh add-food session. The sheet itself writes nothing.
library;

import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/widgets/meal_detail_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FoodItem _food(String name) => FoodItem(
  source: offSource,
  externalId: 'x-$name',
  name: name,
  brands: '',
  rawSourceJson: '{}',
  kcal100g: 380,
);

NutritionEntry _entry({required int id, required String name}) =>
    NutritionEntry(
      id: id,
      uuid: 'uuid-$id',
      mealType: 'breakfast',
      consumedAt: DateTime(2024, 1, 1, 8),
      quantityG: 100,
      kcal: 380,
      foodItem: _food(name),
    );

void _tallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  required List<NutritionEntry> entries,
  void Function(List<NutritionEntry>)? onDuplicate,
}) async {
  _tallSurface(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: LuminaHealthTheme.dark(),
      home: Scaffold(
        body: MealDetailSheet(
          mealLabel: 'Breakfast',
          mealTypeName: 'breakfast',
          mealIcon: Icons.breakfast_dining,
          mealColor: LuminaHealthColors.tertiary,
          entries: entries,
          onUpdateEntry: (entry, {quantityG, mealType}) async => entry,
          onDeleteEntry: (_) async => true,
          onRestoreEntry: (entry) async => entry,
          onAddMore: () {},
          onDuplicate: onDuplicate,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the duplicate action only exists when the callback is wired', (
    tester,
  ) async {
    await _pumpSheet(tester, entries: [_entry(id: 1, name: 'Oatmeal')]);
    expect(find.byKey(const Key('duplicateMeal')), findsNothing);

    await _pumpSheet(
      tester,
      entries: [_entry(id: 1, name: 'Oatmeal')],
      onDuplicate: (_) {},
    );
    expect(find.byKey(const Key('duplicateMeal')), findsOneWidget);
    expect(find.byTooltip('Duplicate meal'), findsOneWidget);
  });

  testWidgets(
    'duplicate hands over the entries as currently shown, so an in-sheet '
    'delete is excluded from the copy',
    (tester) async {
      List<NutritionEntry>? handed;
      await _pumpSheet(
        tester,
        entries: [
          _entry(id: 1, name: 'Oatmeal'),
          _entry(id: 2, name: 'Banana'),
        ],
        onDuplicate: (entries) => handed = entries,
      );

      await tester.drag(find.text('Oatmeal'), const Offset(-800, 0));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('duplicateMeal')));
      await tester.pumpAndSettle();

      expect(handed, isNotNull);
      expect(handed!.map((e) => e.foodItem.name), ['Banana']);
    },
  );

  testWidgets('duplicate is disabled once the meal empties', (tester) async {
    await _pumpSheet(
      tester,
      entries: [_entry(id: 1, name: 'Oatmeal')],
      onDuplicate: (_) {},
    );

    await tester.drag(find.text('Oatmeal'), const Offset(-800, 0));
    await tester.pumpAndSettle();

    final button = tester.widget<IconButton>(
      find.byKey(const Key('duplicateMeal')),
    );
    expect(button.onPressed, isNull);
  });
}
