import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/custom_food_page.dart';
import 'package:fitness_app/features/nutrition/data/food_local_db.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/foods_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/food_detail_page.dart';
import 'package:fitness_app/features/nutrition/widgets/amount_sheet.dart';
import 'package:fitness_app/features/nutrition/widgets/meal_detail_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';

FoodItem _offMince({DateTime? verifiedAt}) => FoodItem(
      backendId: 42,
      source: offSource,
      externalId: '5054070875254',
      barcode: '5054070875254',
      name: 'Lean Beef Mince',
      brands: 'Test Farms',
      kcal100g: 124,
      proteinG100g: 21,
      servingSizeG: 250,
      nutritionBasis: cookedNutritionBasis,
      communityVerifiedAt: verifiedAt,
      rawSourceJson: '{}',
      nutrimentsJson: const {
        'proteins_100g': 21,
        'proteins_unit': 'g',
        'fat_100g': 4.5,
        'fat_unit': 'g',
      },
    );

FoodItem _customFood({int? overridesBackendId}) => FoodItem(
      localId: 1,
      backendId: 7,
      source: customSource,
      externalId: 'cf-1',
      name: 'My Protein Shake',
      brands: '',
      kcal100g: 380,
      proteinG100g: 70,
      overridesBackendId: overridesBackendId,
      rawSourceJson: '{}',
      nutrimentsJson: const {'proteins_100g': 70, 'proteins_unit': 'g'},
    );

Widget _page(FoodItem item) => MaterialApp(
      theme: LuminaHealthTheme.dark(),
      home: FoodDetailPage(
        item: item,
        // Never called in these tests: paths that hit the network or the
        // local db (favorite, save, revert-confirm) are not exercised.
        foodsApi: FoodsApiService(accessToken: 'token'),
        localDb: FoodLocalDb(),
        onLogout: () async {},
      ),
    );

/// Phone-shaped test surface — the page is a scrolling column, and the
/// default 800x600 landscape surface leaves the chips/actions off-screen.
void _phoneView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows provenance, serving info, per-100g facts and edit action',
      (WidgetTester tester) async {
    _phoneView(tester);
    await tester.pumpWidget(
      _page(_offMince(verifiedAt: DateTime.utc(2026, 7, 1))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Lean Beef Mince'), findsOneWidget);
    expect(find.text('Test Farms'), findsOneWidget);
    expect(find.text('124 kcal per 100 g cooked'), findsOneWidget);
    // Provenance chips for all three lineages this item carries.
    expect(find.text('OpenFoodFacts', skipOffstage: false), findsOneWidget);
    expect(
      find.text('Community verified', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('Per 100 g cooked', skipOffstage: false), findsOneWidget);
    // Serving info and the per-100g breakdown.
    expect(
      find.text('Serving size', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('Protein', skipOffstage: false), findsOneWidget);
    expect(
      find.text('Edit nutrition facts', skipOffstage: false),
      findsOneWidget,
    );
    // Not an override: no revert action.
    expect(
      find.text('Revert to original', skipOffstage: false),
      findsNothing,
    );
  });

  testWidgets('tapping a provenance chip explains it',
      (WidgetTester tester) async {
    _phoneView(tester);
    await tester.pumpWidget(
      _page(_offMince(verifiedAt: DateTime.utc(2026, 7, 1))),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Community verified', skipOffstage: false),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Community verified'));
    await tester.pumpAndSettle();

    expect(find.textContaining('independently corrected'), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.textContaining('independently corrected'), findsNothing);
  });

  testWidgets('override shows edited-by-you chip and asks before reverting',
      (WidgetTester tester) async {
    _phoneView(tester);
    await tester.pumpWidget(_page(_customFood(overridesBackendId: 42)));
    await tester.pumpAndSettle();

    expect(find.text('Edited by you', skipOffstage: false), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Revert to original', skipOffstage: false),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Revert to original'));
    await tester.pumpAndSettle();

    expect(find.text('Revert to the original?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Revert to the original?'), findsNothing);
  });

  testWidgets('edit opens the nutrition editor for a custom food',
      (WidgetTester tester) async {
    _phoneView(tester);
    await tester.pumpWidget(_page(_customFood()));
    await tester.pumpAndSettle();

    expect(find.text('Your food', skipOffstage: false), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Edit nutrition facts', skipOffstage: false),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Edit nutrition facts'));
    await tester.pumpAndSettle();

    expect(find.byType(CustomFoodPage), findsOneWidget);
    expect(find.text('Edit food'), findsOneWidget);
  });

  testWidgets('amount sheet header opens details and refreshes the preview',
      (WidgetTester tester) async {
    _phoneView(tester);
    FoodItem? requested;
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Scaffold(
          body: AmountSheet(
            item: _offMince(),
            initialGrams: 100,
            isEditing: false,
            onViewDetails: (item) async {
              requested = item;
              return item.copyWith(kcal100g: 200);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The tappable header advertises itself with a chevron.
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(find.text('Lean Beef Mince'));
    await tester.pumpAndSettle();

    expect(requested?.name, 'Lean Beef Mince');
    // The sheet now previews the item as edited on the detail page.
    expect(find.text('200 kcal per 100g cooked'), findsOneWidget);
  });

  testWidgets('meal detail row expansion links to food details',
      (WidgetTester tester) async {
    _phoneView(tester);
    FoodItem? requested;
    final entry = NutritionEntry(
      id: 1,
      mealType: 'lunch',
      consumedAt: DateTime(2026, 7, 5, 13),
      quantityG: 150,
      kcal: 186,
      foodItem: _offMince(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Scaffold(
          body: MealDetailSheet(
            mealLabel: 'Lunch',
            mealTypeName: 'lunch',
            mealIcon: Icons.lunch_dining,
            entries: [entry],
            onUpdateEntry: (entry, {quantityG, mealType}) async => null,
            onDeleteEntry: (entry) async => true,
            onAddMore: () {},
            onViewFoodDetails: (item) async {
              requested = item;
              return null;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tap the row to expand its breakdown, revealing the details link.
    await tester.tap(find.text('Lean Beef Mince'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Food details'));
    await tester.pumpAndSettle();

    expect(requested?.name, 'Lean Beef Mince');
  });
}
