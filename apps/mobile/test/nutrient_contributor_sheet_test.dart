import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/nutrient_catalog.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/widgets/nutrient_contributor_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FoodItem _food({
  required String name,
  String brand = '',
  Map<String, dynamic>? nutriments,
}) => FoodItem(
  // Rows merge on source+externalId, so each distinct food gets its own id.
  source: offSource,
  externalId: name,
  name: name,
  brands: brand,
  rawSourceJson: '{}',
  nutrimentsJson: nutriments,
);

NutritionEntry _entry(FoodItem food, double quantityG) => NutritionEntry(
  id: 1,
  mealType: 'breakfast',
  consumedAt: DateTime(2024, 1, 1),
  quantityG: quantityG,
  kcal: 0,
  foodItem: food,
);

final _specC = kNutrientCatalog.firstWhere((s) => s.key == 'vitamin_c');

Future<void> _openSheet(
  WidgetTester tester, {
  required List<NutritionEntry> entries,
  Future<List<NutritionEntry>?> Function(FoodItem item)? onEditFood,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: LuminaHealthTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showNutrientContributorSheet(
                context,
                spec: _specC,
                entries: entries,
                onEditFood: onEditFood,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  final orange = _food(
    name: 'Orange',
    nutriments: {'vitamin-c_100g': 50, 'vitamin-c_unit': 'mg'},
  );
  final mystery = _food(name: 'Mystery', brand: 'Acme');

  testWidgets('lists foods with no data in their own section', (tester) async {
    await _openSheet(
      tester,
      entries: [
        _entry(orange, 100),
        // Two logs of the same no-data food merge into one row (140 g).
        _entry(mystery, 100),
        _entry(mystery, 40),
      ],
    );

    expect(find.text('NO DATA FOR VITAMIN C'), findsOneWidget);
    expect(find.text('Mystery'), findsOneWidget);
    expect(find.text('Acme · 140 g'), findsOneWidget);
    // Without an edit callback the rows carry no edit affordance.
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.textContaining('tap one to fill it in'), findsNothing);
    expect(find.textContaining('the total is a floor'), findsOneWidget);
  });

  testWidgets('shows the missing section even with zero contributors', (
    tester,
  ) async {
    await _openSheet(tester, entries: [_entry(mystery, 100)]);

    // "Every food lacks this" must list the foods, not hide behind the
    // empty state — that's the whole point of KAN-92.
    expect(find.text('No source data'), findsNothing);
    expect(find.text('NO DATA FOR VITAMIN C'), findsOneWidget);
    expect(find.text('Mystery'), findsOneWidget);
  });

  testWidgets('tapping a missing food fires the edit callback and re-ranks', (
    tester,
  ) async {
    FoodItem? edited;
    await _openSheet(
      tester,
      entries: [_entry(orange, 100), _entry(mystery, 140)],
      onEditFood: (item) async {
        edited = item;
        // Simulate the owner patching the day's entries with the edited food.
        final fixed = _food(
          name: 'Mystery',
          brand: 'Acme',
          nutriments: {'vitamin-c_100g': 100, 'vitamin-c_unit': 'mg'},
        );
        return [_entry(orange, 100), _entry(fixed, 140)];
      },
    );

    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    await tester.tap(find.text('Mystery'));
    await tester.pumpAndSettle();

    expect(edited?.externalId, 'Mystery');
    // The edited food now carries data: it leaves the missing section and
    // ranks as the top contributor (140 g * 100 mg/100g = 140 mg > 50 mg).
    expect(find.text('NO DATA FOR VITAMIN C'), findsNothing);
    expect(find.text('Mystery'), findsOneWidget);
    expect(find.textContaining('140 mg'), findsOneWidget);
  });
}
