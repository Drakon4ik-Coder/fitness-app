/// KAN-39: swipe-to-delete with Undo in the meal detail sheet — no persistent
/// red delete buttons, optimistic removal, undo restores the exact entry, and
/// a failed delete puts the row back.
library;

import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
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

NutritionEntry _entry({int id = 42, String? uuid}) => NutritionEntry(
  id: id,
  uuid: uuid,
  mealType: 'breakfast',
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

Future<void> _pumpSheet(
  WidgetTester tester, {
  required Future<bool> Function(NutritionEntry) onDelete,
  required Future<NutritionEntry?> Function(NutritionEntry) onRestore,
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
          entries: [_entry(uuid: 'uuid-1')],
          onUpdateEntry: (entry, {quantityG, mealType}) async => entry,
          onDeleteEntry: onDelete,
          onRestoreEntry: onRestore,
          onAddMore: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('rows carry no persistent delete button', (tester) async {
    await _pumpSheet(
      tester,
      onDelete: (_) async => true,
      onRestore: (entry) async => entry,
    );

    expect(find.byIcon(Icons.delete_outline), findsNothing);
    // The gesture stays discoverable to screen readers as an explicit action.
    final rowSemantics = tester.widgetList<Semantics>(find.byType(Semantics));
    expect(
      rowSemantics.where(
        (s) =>
            s.properties.customSemanticsActions?.keys.any(
              (action) => action.label == 'Remove from meal',
            ) ??
            false,
      ),
      isNotEmpty,
    );
  });

  testWidgets('swipe deletes optimistically and Undo restores the entry', (
    tester,
  ) async {
    NutritionEntry? deleted;
    NutritionEntry? restoredRequest;
    await _pumpSheet(
      tester,
      onDelete: (entry) async {
        deleted = entry;
        return true;
      },
      onRestore: (entry) async {
        restoredRequest = entry;
        return entry;
      },
    );

    await tester.drag(find.text('Oatmeal'), const Offset(-800, 0));
    await tester.pumpAndSettle();

    // Row gone, delete persisted, Undo offered — sheet stays open on empty.
    expect(deleted, isNotNull);
    expect(find.text('Oatmeal'), findsNothing);
    expect(find.text('No foods logged yet.'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    // Restored through the repository path with the same identity.
    expect(restoredRequest?.uuid, 'uuid-1');
    expect(find.text('Oatmeal'), findsOneWidget);
  });

  testWidgets('a failed delete puts the row back', (tester) async {
    await _pumpSheet(
      tester,
      onDelete: (_) async => false,
      onRestore: (entry) async => entry,
    );

    await tester.drag(find.text('Oatmeal'), const Offset(-800, 0));
    await tester.pumpAndSettle();

    expect(find.text('Oatmeal'), findsOneWidget);
    expect(find.text("Couldn't remove Oatmeal."), findsOneWidget);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('the edit sheet keeps a visible Remove path with Undo', (
    tester,
  ) async {
    var deleteCalls = 0;
    await _pumpSheet(
      tester,
      onDelete: (_) async {
        deleteCalls++;
        return true;
      },
      onRestore: (entry) async => entry,
    );

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from meal'));
    await tester.pumpAndSettle();

    expect(deleteCalls, 1);
    expect(find.text('Oatmeal'), findsNothing);
    expect(find.text('Undo'), findsOneWidget);
  });
}
