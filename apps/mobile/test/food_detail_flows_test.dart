import 'dart:async';

import 'package:fitness_app/features/nutrition/custom_food_page.dart';
import 'package:fitness_app/features/nutrition/data/api_exceptions.dart';
import 'package:fitness_app/features/nutrition/data/food_local_db.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/foods_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrient_catalog.dart';
import 'package:fitness_app/features/nutrition/food_detail_page.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Persistence flows of the read-first food page (KAN-33, KAN-131):
// favoriting, opening the editor for an unsynced catalog item, saving and
// deleting through the editor's result.

class _FakeLocalDb extends FoodLocalDb {
  final List<FoodItem> upserts = [];
  final Map<int, bool> favorites = {};
  final List<int> deleted = [];

  @override
  Future<FoodItem> upsertFood(FoodItem item) async {
    upserts.add(item);
    return item.localId == null ? item.copyWith(localId: 11) : item;
  }

  @override
  Future<void> setFavorite(int localId, bool isFavorite) async {
    favorites[localId] = isFavorite;
  }

  @override
  Future<bool> updateBackendId(int localId, int backendId) async => true;

  @override
  Future<void> deleteFood(int localId) async => deleted.add(localId);
}

class _FakeFoodsApi extends FoodsApiService {
  _FakeFoodsApi({this.lookupError, this.deleteError})
    : super(accessToken: 'token');

  final ApiException? lookupError;
  final ApiException? deleteError;

  @override
  Future<FoodCheckResult> checkFood({
    required String source,
    required String externalId,
    required String contentHash,
    String? imageSignature,
  }) async {
    if (lookupError != null) throw lookupError!;
    return const FoodCheckResult(
      exists: false,
      upToDate: false,
      foodItemId: null,
      imagesOk: false,
    );
  }

  @override
  Future<FoodIngestResult> ingestFood(FoodItem item) async {
    if (lookupError != null) throw lookupError!;
    return FoodIngestResult(
      item: item.copyWith(backendId: 99),
      imagesOk: false,
    );
  }

  @override
  Future<FoodItem> upsertCustomFood(FoodItem item) async =>
      item.copyWith(backendId: 500);

  @override
  Future<void> deleteCustomFood(int backendId) async {
    if (deleteError != null) throw deleteError!;
  }
}

FoodItem _offItem() => FoodItem(
  source: offSource,
  externalId: '123',
  barcode: '123',
  name: 'Granola',
  brands: 'Acme',
  kcal100g: 450,
  gramsPerPiece: 30,
  pieceUnit: 'bar',
  rawSourceJson: '{}',
);

FoodItem _custom() => FoodItem(
  localId: 3,
  backendId: 7,
  source: customSource,
  externalId: 'cf-1',
  name: 'My Shake',
  brands: '',
  kcal100g: 380,
  rawSourceJson: '{}',
);

void _phoneView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

/// Opens the page through [pushFoodDetailPage] and records what it resolves.
Future<Completer<FoodItem?>> _open(
  WidgetTester tester,
  FoodItem item, {
  FoodsApiService? foodsApi,
  FoodLocalDb? localDb,
  Future<void> Function()? onLogout,
  void Function(FoodItem removed)? onItemReverted,
}) async {
  _phoneView(tester);
  final result = Completer<FoodItem?>();
  await tester.pumpWidget(
    MaterialApp(
      theme: LuminaHealthTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result.complete(
              await pushFoodDetailPage(
                context,
                item: item,
                foodsApi: foodsApi ?? _FakeFoodsApi(),
                localDb: localDb ?? _FakeLocalDb(),
                onLogout: onLogout ?? () async {},
                onItemReverted: onItemReverted,
                catalog: kNutrientCatalog,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

Future<void> _popPage(WidgetTester tester) async {
  await tester.pageBack();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('favoriting an unsaved food stores it first and reports it', (
    tester,
  ) async {
    final db = _FakeLocalDb();
    final result = await _open(tester, _offItem(), localDb: db);

    expect(find.text('1 bar'), findsOneWidget);
    await tester.tap(find.byTooltip('Add to favorites'));
    await tester.pumpAndSettle();
    expect(db.upserts, hasLength(1));
    expect(db.favorites, {11: true});
    expect(find.byTooltip('Remove from favorites'), findsOneWidget);

    await _popPage(tester);
    final updated = await result.future;
    expect(updated?.isFavorite, isTrue);
  });

  testWidgets('an offline id lookup keeps the editor closed with a banner', (
    tester,
  ) async {
    final result = await _open(
      tester,
      _offItem(),
      foodsApi: _FakeFoodsApi(lookupError: ApiException('offline')),
    );
    await tester.tap(find.text('Edit nutrition facts'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not open the editor'), findsOneWidget);
    expect(find.byType(CustomFoodPage), findsNothing);
    await _popPage(tester);
    expect(await result.future, isNull);
  });

  testWidgets('a 401 during the id lookup logs out', (tester) async {
    var logouts = 0;
    await _open(
      tester,
      _offItem(),
      foodsApi: _FakeFoodsApi(
        lookupError: ApiException('expired', statusCode: 401),
      ),
      onLogout: () async => logouts++,
    );
    await tester.tap(find.text('Edit nutrition facts'));
    // Logout tears the whole page down in the app, so it never stops its
    // busy spinner — pump frames instead of settling.
    await tester.pump();
    await tester.pump();
    expect(logouts, 1);
    expect(find.byType(CustomFoodPage), findsNothing);
  });

  testWidgets('editing a catalog item resolves its id and saves the override', (
    tester,
  ) async {
    final db = _FakeLocalDb();
    final result = await _open(tester, _offItem(), localDb: db);

    // Closing the editor without a result changes nothing.
    await tester.tap(find.text('Edit nutrition facts'));
    await tester.pumpAndSettle();
    final editor = tester.widget<CustomFoodPage>(find.byType(CustomFoodPage));
    expect(editor.overrideOf?.backendId, 99);
    await _popPage(tester);
    expect(db.upserts, isEmpty);

    await tester.tap(find.text('Edit nutrition facts'));
    await tester.pumpAndSettle();
    final draft = _offItem().copyWith(
      source: customSource,
      externalId: 'override-1',
      name: 'Granola (mine)',
      overridesBackendId: 99,
    );
    Navigator.of(
      tester.element(find.byType(CustomFoodPage)),
    ).pop(CustomFoodResult.saved(draft));
    await tester.pumpAndSettle();

    expect(db.upserts.single.name, 'Granola (mine)');
    expect(find.text('Granola (mine)'), findsOneWidget);
    await _popPage(tester);
    // The background upsert's synced copy is the last reported change.
    expect((await result.future)?.backendId, 500);
  });

  testWidgets('deleting a custom food from the editor pops with a revert', (
    tester,
  ) async {
    final db = _FakeLocalDb();
    FoodItem? reverted;
    await _open(
      tester,
      _custom(),
      localDb: db,
      onItemReverted: (item) => reverted = item,
    );
    await tester.tap(find.text('Edit nutrition facts'));
    await tester.pumpAndSettle();
    Navigator.of(
      tester.element(find.byType(CustomFoodPage)),
    ).pop(CustomFoodResult.deleted());
    await tester.pumpAndSettle();

    expect(db.deleted, [3]);
    expect(reverted?.externalId, 'cf-1');
    expect(find.byType(FoodDetailPage), findsNothing);
  });

  testWidgets('a failed delete stays on the page with a banner', (
    tester,
  ) async {
    final db = _FakeLocalDb();
    await _open(
      tester,
      _custom(),
      localDb: db,
      foodsApi: _FakeFoodsApi(deleteError: ApiException('offline')),
    );
    await tester.tap(find.text('Edit nutrition facts'));
    await tester.pumpAndSettle();
    Navigator.of(
      tester.element(find.byType(CustomFoodPage)),
    ).pop(CustomFoodResult.deleted());
    await tester.pumpAndSettle();

    expect(db.deleted, isEmpty);
    expect(find.textContaining('Could not remove the food'), findsOneWidget);
    expect(find.byType(FoodDetailPage), findsOneWidget);
  });
}
