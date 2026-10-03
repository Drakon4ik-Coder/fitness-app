import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/nutrition_detail_page.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FoodItem _food(String name, {Map<String, dynamic>? nutriments}) => FoodItem(
  source: offSource,
  externalId: name,
  name: name,
  brands: '',
  rawSourceJson: '{}',
  nutrimentsJson: nutriments,
);

NutritionEntry _entry(FoodItem food, double quantityG) => NutritionEntry(
  id: 1,
  uuid: 'uuid-${food.name}',
  mealType: 'breakfast',
  consumedAt: DateTime(2024, 1, 1),
  quantityG: quantityG,
  kcal: 0,
  foodItem: food,
);

final _orange = _food(
  'Orange',
  nutriments: {'vitamin-c_100g': 50, 'vitamin-c_unit': 'mg'},
);
final _mystery = _food('Mystery');

Future<void> _pump(
  WidgetTester tester, {
  required List<NutritionEntry> entries,
  Map<String, dynamic>? serverNutrients,
  Future<FoodItem?> Function(FoodItem item)? onEditFood,
}) async {
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: LuminaHealthTheme.dark(),
      home: NutritionDetailPage(
        dateLabel: 'Today',
        eatenKcal: 120,
        entries: entries,
        serverNutrients: serverNutrients,
        onEditFood: onEditFood,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an empty day shows the empty state', (tester) async {
    await _pump(tester, entries: const []);
    expect(find.text('TODAY'), findsOneWidget);
    expect(
      find.text('Tap any nutrient to see its top food sources.'),
      findsNothing,
    );
  });

  testWidgets('a food edited from the sources sheet patches the day (KAN-92)', (
    tester,
  ) async {
    final requested = <String>[];
    await _pump(
      tester,
      entries: [_entry(_orange, 100), _entry(_mystery, 140)],
      // A stale server map that still lacks the edited food's vitamin C.
      serverNutrients: {
        'vitamin_c': {'amount': 50, 'unit': 'mg', 'total': 2, 'reported': 1},
      },
      onEditFood: (item) async {
        requested.add(item.name);
        return _food(
          'Mystery',
          nutriments: {'vitamin-c_100g': 100, 'vitamin-c_unit': 'mg'},
        );
      },
    );

    await tester.tap(find.text('Vitamin C'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mystery'));
    await tester.pumpAndSettle();

    expect(requested, ['Mystery']);
    // The page dropped the stale server map and re-aggregated on-device:
    // 50 mg (orange) + 140 mg (fixed mystery) = 190 mg.
    expect(find.textContaining('190'), findsWidgets);
  });

  testWidgets('a cancelled edit leaves the day untouched', (tester) async {
    await _pump(
      tester,
      entries: [_entry(_orange, 100), _entry(_mystery, 140)],
      onEditFood: (_) async => null,
    );

    await tester.tap(find.text('Vitamin C'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mystery'));
    await tester.pumpAndSettle();
    expect(find.text('NO DATA FOR VITAMIN C'), findsOneWidget);
  });
}
