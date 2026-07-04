import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/custom_food_page.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';

/// Opens the form, fills [fields] (keyed by field label), and returns a
/// getter for the result the page pops with — call it after tapping save.
Future<CustomFoodResult? Function()> _openForm(
  WidgetTester tester, {
  FoodItem? initial,
  Map<String, String> fields = const {},
}) async {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  CustomFoodResult? result;
  await tester.pumpWidget(
    MaterialApp(
      theme: LuminaHealthTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await Navigator.of(context).push<CustomFoodResult>(
                  MaterialPageRoute(
                    builder: (_) => CustomFoodPage(initial: initial),
                  ),
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

  for (final entry in fields.entries) {
    final finder = find.widgetWithText(TextFormField, entry.key);
    await tester.ensureVisible(finder);
    await tester.enterText(finder, entry.value);
  }
  await tester.pumpAndSettle();
  return () => result;
}

Future<void> _tapSave(WidgetTester tester, {bool editing = false}) async {
  final button = find.widgetWithText(
    ElevatedButton,
    editing ? 'Save changes' : 'Create food',
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('builds a custom food with OFF-format nutriments',
      (tester) async {
    final resultOf = await _openForm(
      tester,
      fields: {
        'Name': "Mum's granola",
        'Calories': '450',
        'Protein': '12',
        'Carbs': '55',
        'Fat': '20',
      },
    );
    await _tapSave(tester);

    final item = resultOf()?.item;
    expect(item, isNotNull);
    expect(item!.source, customSource);
    expect(item.isCustom, isTrue);
    expect(item.barcode, isNull);
    expect(item.externalId, startsWith('cf-'));
    expect(item.name, "Mum's granola");
    expect(item.kcal100g, 450);
    expect(item.proteinG100g, 12);
    expect(item.carbsG100g, 55);
    expect(item.fatG100g, 20);
    // Nutriments blob uses OFF keys so the breakdown/pills work unchanged.
    expect(item.nutrimentsJson!['energy-kcal_100g'], 450);
    expect(item.nutrimentsJson!['proteins_100g'], 12);
    expect(item.nutrimentsJson!['proteins_unit'], 'g');
  });

  testWidgets('micros entered in the expandable groups land in the blob',
      (tester) async {
    final resultOf = await _openForm(
      tester,
      fields: {'Name': 'Fortified thing', 'Calories': '100'},
    );

    final vitaminsTile = find.text('Vitamins');
    await tester.ensureVisible(vitaminsTile);
    await tester.tap(vitaminsTile);
    await tester.pumpAndSettle();
    final vitC = find.widgetWithText(TextFormField, 'Vitamin C');
    await tester.ensureVisible(vitC);
    await tester.enterText(vitC, '80');
    await tester.pumpAndSettle();
    await _tapSave(tester);

    final item = resultOf()?.item;
    expect(item, isNotNull);
    expect(item!.nutrimentsJson!['vitamin-c_100g'], 80);
    expect(item.nutrimentsJson!['vitamin-c_unit'], 'mg');
    // Absent nutrients stay absent rather than being written as zeros.
    expect(item.nutrimentsJson!.containsKey('iron_100g'), isFalse);
  });

  testWidgets('shows the Atwater hint when kcal disagrees with macros',
      (tester) async {
    await _openForm(
      tester,
      fields: {
        'Name': 'Sketchy bar',
        'Calories': '100',
        'Protein': '20',
        'Carbs': '30',
        'Fat': '10',
      },
    );

    // 4*20 + 4*30 + 9*10 = 290 vs 100 stated.
    expect(find.textContaining('Macros suggest ~290 kcal'), findsOneWidget);
  });

  testWidgets('no Atwater hint when kcal is consistent', (tester) async {
    await _openForm(
      tester,
      fields: {
        'Name': 'Honest bar',
        'Calories': '290',
        'Protein': '20',
        'Carbs': '30',
        'Fat': '10',
      },
    );

    expect(find.textContaining('Macros suggest'), findsNothing);
  });

  testWidgets('requires name and calories', (tester) async {
    final resultOf = await _openForm(tester, fields: {});
    await _tapSave(tester);

    expect(resultOf(), isNull);
    expect(find.text('Enter a name'), findsOneWidget);
    expect(find.text('Required'), findsOneWidget);
  });

  testWidgets('editing prefills fields and keeps the external id',
      (tester) async {
    final existing = FoodItem(
      source: customSource,
      externalId: 'cf-keep-me',
      name: 'Old name',
      brands: 'Old brand',
      kcal100g: 200,
      proteinG100g: 10,
      rawSourceJson: '{}',
      nutrimentsJson: const {
        'energy-kcal_100g': 200,
        'proteins_100g': 10,
        'proteins_unit': 'g',
      },
    );

    final resultOf = await _openForm(
      tester,
      initial: existing,
      fields: {'Name': 'New name'},
    );
    await _tapSave(tester, editing: true);

    final item = resultOf()?.item;
    expect(item, isNotNull);
    expect(item!.externalId, 'cf-keep-me');
    expect(item.name, 'New name');
    expect(item.kcal100g, 200);
    expect(item.proteinG100g, 10);
  });

  testWidgets('delete asks for confirmation and pops a deleted result',
      (tester) async {
    final existing = FoodItem(
      source: customSource,
      externalId: 'cf-doomed',
      name: 'Doomed food',
      brands: '',
      kcal100g: 100,
      rawSourceJson: '{}',
    );

    final resultOf = await _openForm(tester, initial: existing);

    // No delete affordance in create mode is covered implicitly: the button
    // only renders with an initial item.
    final deleteButton = find.text('Delete food');
    await tester.ensureVisible(deleteButton);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    // Cancel keeps the form open.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(resultOf(), isNull);
    expect(find.text('Save changes'), findsOneWidget);

    // Confirm pops with deleted=true.
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(resultOf(), isNotNull);
    expect(resultOf()!.deleted, isTrue);
    expect(resultOf()!.item, isNull);
  });
}
