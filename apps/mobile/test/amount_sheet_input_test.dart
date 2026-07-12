import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/widgets/amount_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FoodItem _food() => FoodItem(
  source: offSource,
  externalId: 'x',
  name: 'Orange juice',
  brands: '',
  rawSourceJson: '{}',
  kcal100g: 45,
  proteinG100g: 1,
  carbsG100g: 10,
  fatG100g: 0,
);

Future<void> _pumpSheet(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: LuminaHealthTheme.dark(),
      home: Scaffold(
        body: AmountSheet(item: _food(), initialGrams: 100, isEditing: false),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

FilledButton _submitButton(WidgetTester tester) => tester.widget<FilledButton>(
  find.ancestor(
    of: find.text('Add to meal'),
    matching: find.byType(FilledButton),
  ),
);

const _hint = 'Enter an amount above 0';

void main() {
  testWidgets('amount field filters out non-numeric characters', (
    tester,
  ) async {
    await _pumpSheet(tester);

    await tester.enterText(find.byType(TextField), '12abc!');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '12',
    );
  });

  testWidgets('invalid amount shows an inline hint and disables submit', (
    tester,
  ) async {
    await _pumpSheet(tester);

    // Valid initial amount: no hint, button live.
    expect(find.text(_hint), findsNothing);
    expect(_submitButton(tester).onPressed, isNotNull);

    await tester.enterText(find.byType(TextField), '0');
    await tester.pump();
    expect(find.text(_hint), findsOneWidget);
    expect(_submitButton(tester).onPressed, isNull);

    // Cleared field is invalid too.
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.text(_hint), findsOneWidget);
    expect(_submitButton(tester).onPressed, isNull);

    // A malformed number survives the character filter but still parses null.
    await tester.enterText(find.byType(TextField), '1.2.3');
    await tester.pump();
    expect(find.text(_hint), findsOneWidget);
    expect(_submitButton(tester).onPressed, isNull);
  });

  testWidgets('hint clears and submit re-enables on valid input', (
    tester,
  ) async {
    await _pumpSheet(tester);

    await tester.enterText(find.byType(TextField), '0');
    await tester.pump();
    expect(find.text(_hint), findsOneWidget);

    await tester.enterText(find.byType(TextField), '150');
    await tester.pump();
    expect(find.text(_hint), findsNothing);
    expect(_submitButton(tester).onPressed, isNotNull);
    // The unit label returns in the hint's slot.
    expect(find.textContaining('grams'), findsOneWidget);
  });
}
