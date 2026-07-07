import 'package:dio/dio.dart';
import 'package:fitness_app/core/app_log.dart';
import 'package:fitness_app/features/nutrition/add_food_page.dart';
import 'package:fitness_app/features/nutrition/data/food_local_db.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/foods_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_local_store.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_repository.dart';
import 'package:fitness_app/features/nutrition/data/off_client.dart';
import 'package:fitness_app/features/nutrition/data/off_rate_limiter.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'in_memory_nutrition_store.dart';

/// In-memory stand-in for the sqflite-backed catalog cache. Only the calls
/// the add-food page makes are overridden; anything else reaching the real
/// implementation would blow up on the missing platform channel — which is
/// exactly the signal we want in a test.
class _FakeLocalDb extends FoodLocalDb {
  _FakeLocalDb({this.recents = const []});

  final List<FoodItem> recents;
  final List<FoodItem> upserted = [];
  final List<int> lastUsedTouches = [];
  int _nextLocalId = 1;

  @override
  Future<List<FoodItem>> fetchRecentFoods({int limit = 20}) async => recents;

  @override
  Future<List<FoodItem>> fetchFavorites({int limit = 20}) async => const [];

  @override
  Future<List<FoodItem>> searchFoods(String query, {int limit = 20}) async =>
      recents
          .where((i) => i.name.toLowerCase().contains(query.toLowerCase()))
          .toList();

  @override
  Future<FoodItem?> fetchOverrideForBarcode(String barcode) async => null;

  @override
  Future<FoodItem> upsertFood(FoodItem item) async {
    final stored = item.localId == null
        ? item.copyWith(localId: _nextLocalId++)
        : item;
    upserted.add(stored);
    return stored;
  }

  @override
  Future<void> updateLastUsed(int localId, DateTime usedAt) async {
    lastUsedTouches.add(localId);
  }
}

/// Backend foods API that never leaves the process: typeahead serves canned
/// results, and anything that would mutate server state fails the test loudly.
class _FakeFoodsApi extends FoodsApiService {
  _FakeFoodsApi({this.typeaheadResults = const []})
    : super(accessToken: 'test-token');

  final List<FoodItem> typeaheadResults;

  @override
  Future<List<FoodItem>> typeahead(String query, {int limit = 10}) async =>
      typeaheadResults;

  @override
  Future<FoodItem> upsertCustomFood(FoodItem item) async =>
      throw StateError('unexpected upsertCustomFood');

  @override
  Future<FoodIngestResult> ingestFood(FoodItem item) async =>
      throw StateError('unexpected ingestFood');
}

class _FakeOffClient extends OffClient {
  _FakeOffClient({
    this.searchResults = const [],
    this.productsByBarcode = const {},
  }) : super(dio: Dio(), rateLimiter: OffRateLimiter());

  final List<OffProductResponse> searchResults;
  final Map<String, OffProductResponse> productsByBarcode;
  final List<String> fetchedBarcodes = [];

  @override
  Future<List<OffProductResponse>> searchProducts(
    String query, {
    int pageSize = 10,
    String? categoryTag,
    CancelToken? cancelToken,
  }) async => searchResults;

  @override
  Future<OffProductResponse?> fetchProduct(String barcode) async {
    fetchedBarcodes.add(barcode);
    return productsByBarcode[barcode];
  }
}

/// An OFF search/product payload in the raw map shape [OffMapper] consumes.
OffProductResponse makeOffResponse({
  required String barcode,
  required String name,
  String? servingSize,
  double completeness = 0.9,
}) {
  final product = {
    'code': barcode,
    'product_name': name,
    'brands': 'Test Brand',
    'completeness': completeness,
    if (servingSize != null) 'serving_size': servingSize,
    'nutriments': {
      'energy-kcal_100g': 200,
      'proteins_100g': 10,
      'carbohydrates_100g': 20,
      'fat_100g': 5,
    },
  };
  return OffProductResponse(
    product: product,
    rawJson: '{"product": {"product_name": "$name"}}',
  );
}

/// Repository over the in-memory store with a dead network, so createEntry
/// takes the offline path (KAN-28): entry stored locally, op queued.
NutritionRepository _offlineRepository(NutritionLocalStore store) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ),
        );
      },
    ),
  );
  return NutritionRepository(
    api: NutritionApiService(accessToken: 'test-token', dio: dio),
    store: store,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The dead-network outbox push logs its swallowed DioException through the
  // seam; keep the test output clean.
  setUp(() => appErrorLogger = (context, error, stackTrace) {});
  tearDown(() => appErrorLogger = null);

  Future<Future<bool?>> pumpAddFoodPage(
    WidgetTester tester, {
    required _FakeLocalDb localDb,
    required NutritionRepository repository,
    _FakeFoodsApi? foodsApi,
    _FakeOffClient? offClient,
    Future<String?> Function(BuildContext)? scanBarcode,
  }) async {
    late Future<bool?> result;
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              result = Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => AddFoodPage(
                    localDb: localDb,
                    foodsApi: foodsApi ?? _FakeFoodsApi(),
                    repository: repository,
                    offClient: offClient ?? _FakeOffClient(),
                    onLogout: () async {},
                    selectedDate: DateUtils.dateOnly(DateTime.now()),
                    scanBarcode: scanBarcode,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  /// Types [query] and rides out the live-search debounce (300 ms) so the
  /// backend + OFF results have landed.
  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  testWidgets('quick-add from recents, then submit logs the entry and pops', (
    WidgetTester tester,
  ) async {
    final localDb = _FakeLocalDb(recents: [makeTestFood(name: 'Oatmeal')]);
    final store = InMemoryNutritionStore();
    final result = await pumpAddFoodPage(
      tester,
      localDb: localDb,
      repository: _offlineRepository(store),
    );

    // Recents are shown; nothing staged yet, so no log bar.
    expect(find.text('Oatmeal'), findsOneWidget);
    expect(find.text('ADDED ITEMS'), findsNothing);

    // One tap stages the food with its smart default (100 g here → 150 kcal).
    await tester.ensureVisible(find.text('Oatmeal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Oatmeal'));
    await tester.pumpAndSettle();
    expect(find.text('ADDED ITEMS'), findsOneWidget);
    expect(find.text('1 item'), findsOneWidget);
    expect(find.text('150 kcal total'), findsOneWidget);
    expect(find.text('Log to Breakfast'), findsOneWidget);

    await tester.tap(find.text('Log to Breakfast'));
    await tester.pumpAndSettle();

    // The entry landed in the local store via the offline path: stored as
    // pending with a queued create op, and the page popped true.
    expect(store.entries, hasLength(1));
    final entry = store.entries.values.single;
    expect(entry.quantityG, 100);
    expect(entry.mealType, 'breakfast');
    expect(entry.pending, isTrue);
    expect(store.outbox, hasLength(1));
    expect(localDb.lastUsedTouches, hasLength(1));
    expect(await result, isTrue);
  });

  testWidgets('tapping an added food opens the editor instead of duplicating', (
    WidgetTester tester,
  ) async {
    final localDb = _FakeLocalDb(recents: [makeTestFood(name: 'Oatmeal')]);
    await pumpAddFoodPage(
      tester,
      localDb: localDb,
      repository: _offlineRepository(InMemoryNutritionStore()),
    );

    await tester.ensureVisible(find.text('Oatmeal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Oatmeal'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove Oatmeal'), findsOneWidget);

    // The result card now reads as added; tapping it edits the staged amount
    // (no second copy). 'Oatmeal' appears twice now — staged tile first in
    // the column, result card last.
    final addedCard = find.text('Oatmeal').last;
    await tester.ensureVisible(addedCard);
    await tester.pumpAndSettle();
    await tester.tap(addedCard);
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget);
    expect(find.byTooltip('Remove Oatmeal'), findsOneWidget);

    // Removing from the sheet unstages it and the log bar disappears.
    await tester.tap(find.text('Remove from meal'));
    await tester.pumpAndSettle();
    expect(find.text('ADDED ITEMS'), findsNothing);
    expect(find.text('Log to Breakfast'), findsNothing);
  });

  testWidgets('empty recents show the search/scan nudge and custom-food CTA', (
    WidgetTester tester,
  ) async {
    await pumpAddFoodPage(
      tester,
      localDb: _FakeLocalDb(),
      repository: _offlineRepository(InMemoryNutritionStore()),
    );

    expect(find.text('Search for a food or scan a barcode'), findsOneWidget);
    expect(find.text('Create custom food'), findsOneWidget);
  });

  testWidgets(
    'search merges local, backend, and OFF results, deduping by barcode '
    'and hiding low-completeness OFF hits',
    (WidgetTester tester) async {
      final localItem = makeTestFood(
        name: 'Oatmeal Local',
        backendId: null,
      ).copyWith(barcode: '111');
      // Backend re-serves the same barcode as the local hit (dedup) plus a
      // distinct item of its own.
      final backendDupe = makeTestFood(
        name: 'Oatmeal Local Server Copy',
        backendId: 41,
      ).copyWith(barcode: '111');
      final backendOnly = makeTestFood(name: 'Oatmeal Backend', backendId: 42);
      await pumpAddFoodPage(
        tester,
        localDb: _FakeLocalDb(recents: [localItem]),
        repository: _offlineRepository(InMemoryNutritionStore()),
        foodsApi: _FakeFoodsApi(typeaheadResults: [backendDupe, backendOnly]),
        offClient: _FakeOffClient(
          searchResults: [
            makeOffResponse(barcode: '222', name: 'Oatmeal OFF'),
            makeOffResponse(
              barcode: '333',
              name: 'Oatmeal Junk',
              completeness: 0.2,
            ),
          ],
        ),
      );

      await search(tester, 'oatmeal');

      // Local wins the shared barcode; the backend copy is deduped away.
      expect(find.text('Oatmeal Local', skipOffstage: false), findsOneWidget);
      expect(find.text('Oatmeal Local Server Copy'), findsNothing);
      expect(find.text('Oatmeal Backend', skipOffstage: false), findsOneWidget);
      // OFF results pass the completeness floor; the sparse duplicate-prone
      // hit is hidden while a good hit exists.
      expect(find.text('Oatmeal OFF', skipOffstage: false), findsOneWidget);
      expect(find.text('Oatmeal Junk', skipOffstage: false), findsNothing);
    },
  );

  testWidgets(
    'tapping a serving-less OFF result enriches it first, so the quick-add '
    'default lands on a whole serving',
    (WidgetTester tester) async {
      // OFF text search omits serving data; the full product carries it.
      final off = _FakeOffClient(
        searchResults: [makeOffResponse(barcode: '555', name: 'Choco Bar')],
        productsByBarcode: {
          '555': makeOffResponse(
            barcode: '555',
            name: 'Choco Bar',
            servingSize: '30 g',
          ),
        },
      );
      await pumpAddFoodPage(
        tester,
        localDb: _FakeLocalDb(),
        repository: _offlineRepository(InMemoryNutritionStore()),
        offClient: off,
      );

      await search(tester, 'choco');
      final card = find.text('Choco Bar', skipOffstage: false).first;
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();

      // The tap triggered exactly one enrichment fetch, and the staged
      // amount is one 30 g serving (200 kcal/100g → 60 kcal), not 100 g.
      expect(off.fetchedBarcodes, ['555']);
      expect(find.text('1 serving (30 g) • 60 kcal'), findsOneWidget);
    },
  );

  testWidgets('re-scanning the same barcode within the cooldown is ignored', (
    WidgetTester tester,
  ) async {
    final off = _FakeOffClient(
      productsByBarcode: {
        '777': makeOffResponse(
          barcode: '777',
          name: 'Scanned Snack',
          servingSize: '25 g',
        ),
      },
    );
    await pumpAddFoodPage(
      tester,
      localDb: _FakeLocalDb(),
      repository: _offlineRepository(InMemoryNutritionStore()),
      offClient: off,
      scanBarcode: (_) async => '777',
    );

    await tester.tap(find.byTooltip('Scan barcode'));
    await tester.pumpAndSettle();
    expect(find.text('Scanned Snack', skipOffstage: false), findsOneWidget);
    expect(off.fetchedBarcodes, ['777']);

    // The camera fires repeatedly while the package stays in frame — a
    // second hit inside the 3 s cooldown must not refetch.
    await tester.tap(find.byTooltip('Scan barcode'));
    await tester.pumpAndSettle();
    expect(off.fetchedBarcodes, ['777']);
    expect(find.text('Scanned Snack', skipOffstage: false), findsOneWidget);
  });
}
