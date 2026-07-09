import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/nutrient_catalog.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/widgets/meal_detail_sheet.dart';
import 'package:fitness_app/features/nutrition/widgets/nutrient_breakdown_view.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FoodItem _food(Map<String, dynamic>? nutriments) => FoodItem(
  source: offSource,
  externalId: 'x',
  name: 'Orange juice',
  brands: '',
  rawSourceJson: '{}',
  kcal100g: 45,
  nutrimentsJson: nutriments,
);

NutritionEntry _entry(Map<String, dynamic>? nutriments) => NutritionEntry(
  id: 7,
  mealType: 'breakfast',
  consumedAt: DateTime(2024, 1, 1),
  quantityG: 200,
  kcal: 90,
  foodItem: _food(nutriments),
);

void main() {
  testWidgets('breakdown view with showEmptyRows=false hides no-data rows', (
    tester,
  ) async {
    final totals = aggregateNutrients([
      _entry({
        'proteins_100g': 1,
        'vitamin-c_100g': 50,
        'vitamin-c_unit': 'mg',
      }),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: NutrientBreakdownView(totals: totals, showEmptyRows: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Vitamin C'), findsOneWidget);
    expect(find.text('Protein'), findsOneWidget);
    // Nutrients with no source data are omitted entirely (not "no data" rows).
    expect(find.text('— no data'), findsNothing);
    expect(find.text('Iron'), findsNothing);
  });

  testWidgets('breakdown view shows a placeholder when nothing has data', (
    tester,
  ) async {
    final totals = aggregateNutrients([_entry(null)]);
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Scaffold(
          body: NutrientBreakdownView(
            totals: totals,
            showEmptyRows: false,
            emptyDataMessage: 'No detailed nutrient data for this food.',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('No detailed nutrient data for this food.'),
      findsOneWidget,
    );
  });

  testWidgets('breakdown view marks an incomplete macro as partial', (
    tester,
  ) async {
    // Two foods; only one reports protein -> protein total is a floor.
    final totals = aggregateNutrients([
      _entry({'proteins_100g': 10}),
      _entry({'carbohydrates_100g': 20}),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: NutrientBreakdownView(totals: totals, showEmptyRows: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Protein'), findsOneWidget);
    expect(find.text('partial'), findsWidgets);
    // The floor value leads with "~".
    expect(find.textContaining('~'), findsWidgets);
  });

  testWidgets('over-target row goes amber only for opted-in nutrients', (
    tester,
  ) async {
    // 200 g at 5 g salt / 100 g = 10 g, over the 6 g daily target.
    final totals = aggregateNutrients([
      _entry({'salt_100g': 5, 'salt_unit': 'g'}),
    ]);

    Future<void> pump(Set<String> warnNutrients) => tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: NutrientBreakdownView(
              totals: totals,
              showEmptyRows: false,
              warnNutrients: warnNutrients,
            ),
          ),
        ),
      ),
    );

    Color? saltValueColor() =>
        tester.widget<Text>(find.textContaining('10 / 6 g')).style?.color;

    // Default (no opt-ins): over is neutral information, not amber.
    await pump(const {});
    await tester.pumpAndSettle();
    expect(saltValueColor(), isNot(LuminaHealthColors.warning));

    // Opted in: the same row warns.
    await pump(const {'salt'});
    await tester.pumpAndSettle();
    expect(saltValueColor(), LuminaHealthColors.warning);
  });

  testWidgets('meal-detail row expands to reveal the food breakdown', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Scaffold(
          body: MealDetailSheet(
            mealLabel: 'Breakfast',
            mealTypeName: 'breakfast',
            mealIcon: Icons.breakfast_dining,
            entries: [
              _entry({
                'proteins_100g': 1,
                'vitamin-c_100g': 50,
                'vitamin-c_unit': 'mg',
              }),
            ],
            onUpdateEntry: (_, {quantityG, mealType}) async => null,
            onDeleteEntry: (_) async => true,
            onRestoreEntry: (entry) async => entry,
            onAddMore: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Collapsed: the per-food nutrient rows aren't shown yet.
    expect(find.text('Vitamin C'), findsNothing);

    await tester.tap(find.text('Orange juice'));
    await tester.pumpAndSettle();

    expect(find.text('Vitamin C'), findsOneWidget);
  });
}
