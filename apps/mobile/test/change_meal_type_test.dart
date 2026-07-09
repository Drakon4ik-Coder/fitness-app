import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/widgets/amount_sheet.dart';
import 'package:fitness_app/features/nutrition/widgets/meal_detail_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FoodItem _food() => FoodItem(
  source: offSource,
  externalId: 'x',
  name: 'Oatmeal',
  brands: '',
  rawSourceJson: '{}',
  kcal100g: 380,
);

NutritionEntry _entry(String mealType, {int id = 42}) => NutritionEntry(
  id: id,
  mealType: mealType,
  consumedAt: DateTime(2024, 1, 1, 8),
  quantityG: 100,
  kcal: 380,
  foodItem: _food(),
);

void _tallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('edit sheet shows the meal selector and returns the new meal', (
    tester,
  ) async {
    _tallSurface(tester);
    AmountResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showAmountSheet(
                    context: ctx,
                    item: _food(),
                    initialGrams: 100,
                    isEditing: true,
                    initialMealType: 'breakfast',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Selector present with all four meals.
    expect(find.widgetWithText(ChoiceChip, 'Breakfast'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Lunch'), findsOneWidget);

    await tester.tap(find.text('Lunch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.mealType, 'lunch');
    expect(result!.grams, 100);
  });

  testWidgets('add mode (no initial meal) shows no selector', (tester) async {
    _tallSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Scaffold(
          body: AmountSheet(item: _food(), initialGrams: 100, isEditing: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('MEAL'), findsNothing);
    expect(find.widgetWithText(ChoiceChip, 'Lunch'), findsNothing);
  });

  testWidgets('moving a meal calls onUpdateEntry and drops it from the list', (
    tester,
  ) async {
    _tallSurface(tester);
    String? capturedMeal;
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Scaffold(
          body: MealDetailSheet(
            mealLabel: 'Breakfast',
            mealTypeName: 'breakfast',
            mealIcon: Icons.breakfast_dining,
            entries: [_entry('breakfast')],
            onUpdateEntry: (entry, {quantityG, mealType}) async {
              capturedMeal = mealType;
              return _entry(mealType ?? entry.mealType);
            },
            onDeleteEntry: (_) async => true,
            onRestoreEntry: (entry) async => entry,
            onAddMore: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dinner'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(capturedMeal, 'dinner');
  });

  testWidgets('move all re-categorizes every food in the meal', (tester) async {
    _tallSurface(tester);
    final movedTo = <int, String?>{};
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Scaffold(
          body: MealDetailSheet(
            mealLabel: 'Breakfast',
            mealTypeName: 'breakfast',
            mealIcon: Icons.breakfast_dining,
            entries: [_entry('breakfast', id: 1), _entry('breakfast', id: 2)],
            onUpdateEntry: (entry, {quantityG, mealType}) async {
              movedTo[entry.id] = mealType;
              return _entry(mealType ?? entry.mealType, id: entry.id);
            },
            onDeleteEntry: (_) async => true,
            onRestoreEntry: (entry) async => entry,
            onAddMore: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Open the "Move all to…" picker from the header action.
    await tester.tap(find.byIcon(Icons.drive_file_move_outline));
    await tester.pumpAndSettle();
    // The current meal is excluded from the target list (header still shows it).
    expect(find.text('Move all to…'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Breakfast'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Lunch'), findsOneWidget);

    await tester.tap(find.text('Lunch'));
    await tester.pumpAndSettle();

    // Every entry was moved to lunch.
    expect(movedTo[1], 'lunch');
    expect(movedTo[2], 'lunch');
  });
}
