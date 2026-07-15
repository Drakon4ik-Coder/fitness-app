import 'package:dio/dio.dart';
import 'package:fitness_app/core/app_log.dart';
import 'package:fitness_app/features/nutrition/add_food_page.dart';
import 'package:fitness_app/features/nutrition/custom_food_page.dart';
import 'package:fitness_app/features/nutrition/data/api_exceptions.dart';
import 'package:fitness_app/features/nutrition/data/fatsecret_client.dart';
import 'package:fitness_app/features/nutrition/data/food_local_db.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/foods_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_local_store.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_repository.dart';
import 'package:fitness_app/features/nutrition/data/off_client.dart';
import 'package:fitness_app/features/nutrition/data/off_rate_limiter.dart';
import 'package:fitness_app/features/nutrition/food_detail_page.dart';
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
  final List<int> deletedLocalIds = [];
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

  @override
  Future<void> deleteFood(int localId) async {
    deletedLocalIds.add(localId);
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

/// Fake FatSecret client: search/get results are canned per test, and every
/// `getFood` call is recorded so a test can assert exactly one enrichment
/// fetch happened (mirrors `_FakeOffClient.fetchedBarcodes`).
class _FakeFatSecretClient extends FatSecretClient {
  _FakeFatSecretClient({
    this.searchResults = const [],
    this.foodsById = const {},
    this.getFoodError,
  }) : super(
         accessToken: 'test-token',
         dio: Dio(),
         rateLimiter: OffRateLimiter(),
       );

  final List<Map<String, dynamic>> searchResults;
  final Map<String, Map<String, dynamic>> foodsById;
  final List<String> fetchedFoodIds = [];

  @override
  Future<List<Map<String, dynamic>>> searchFoods(
    String query, {
    int maxResults = 10,
    CancelToken? cancelToken,
  }) async => searchResults;

  /// Thrown from [getFood] when set (e.g. a 401 [ApiException] to exercise
  /// the enrich path's session-expiry routing).
  final Object? getFoodError;

  @override
  Future<Map<String, dynamic>?> getFood(String foodId) async {
    fetchedFoodIds.add(foodId);
    final error = getFoodError;
    if (error != null) throw error;
    return foodsById[foodId];
  }
}

/// A FatSecret `foods.search` hit in the raw map shape [FatSecretMapper]
/// consumes. Defaults to a per-100g description so `mapSummary` fills macros;
/// pass `description: null` for a non-100g basis (macros stay null until
/// enrich).
Map<String, dynamic> makeFatSecretSearchHit({
  required String foodId,
  required String name,
  String brand = '',
  String? description =
      'Per 100g - Calories: 200kcal | Fat: 5.00g | Carbs: 20.00g | '
      'Protein: 10.00g',
}) {
  return {
    'food_id': foodId,
    'food_name': name,
    'brand_name': brand,
    'food_type': 'Brand',
    if (description != null) 'food_description': description,
  };
}

/// A FatSecret `food.get.v4` detail whose single serving is a countable piece
/// (e.g. "1 burger"), the payoff piece-derivation case from KAN-67.
Map<String, dynamic> makeFatSecretDetail({
  required String foodId,
  required String name,
  double metricGrams = 200,
  double calories = 400,
  String measurementDescription = 'burger',
}) {
  return {
    'food_id': foodId,
    'food_name': name,
    'servings': {
      'serving': {
        'serving_description': '1 $measurementDescription',
        'metric_serving_amount': metricGrams.toString(),
        'metric_serving_unit': 'g',
        'number_of_units': '1.000',
        'measurement_description': measurementDescription,
        'calories': calories.toString(),
        'protein': '10.00',
        'carbohydrate': '30.00',
        'fat': '15.00',
      },
    },
  };
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

Dio _deadNetworkDio() {
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
  return dio;
}

/// Repository over the in-memory store with a dead network, so createEntry
/// takes the offline path (KAN-28): entry stored locally, op queued.
NutritionRepository _offlineRepository(NutritionLocalStore store) {
  return NutritionRepository(
    api: NutritionApiService(accessToken: 'test-token', dio: _deadNetworkDio()),
    store: store,
  );
}

/// Offline repository whose createEntry can be told to reject specific foods
/// once — the shape of a mid-list submit failure (KAN-53).
class _FlakyCreateRepository extends NutritionRepository {
  _FlakyCreateRepository({required super.api, required super.store});

  /// Food names whose next createEntry call throws; each fails only once.
  final Set<String> failNextFor = {};
  final List<String> createdFoods = [];

  @override
  Future<NutritionEntry> createEntry({
    required FoodItem food,
    required String mealType,
    required double quantityG,
    required DateTime consumedAt,
  }) async {
    if (failNextFor.remove(food.name)) {
      throw ApiException('Server rejected the entry.');
    }
    createdFoods.add(food.name);
    return super.createEntry(
      food: food,
      mealType: mealType,
      quantityG: quantityG,
      consumedAt: consumedAt,
    );
  }
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
    _FakeFatSecretClient? fatsecretApi,
    List<StagedFood> initialItems = const [],
    Future<String?> Function(BuildContext)? scanBarcode,
    Future<void> Function()? onLogout,
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
                    // Null unless a test opts in — feature off by default,
                    // matching AddFoodPage's own nullable fatsecretApi.
                    fatsecretApi: fatsecretApi,
                    onLogout: onLogout ?? () async {},
                    selectedDate: DateUtils.dateOnly(DateTime.now()),
                    initialItems: initialItems,
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

  testWidgets(
    'duplicate-seeded foods arrive pre-staged at their logged amounts and '
    'log as-is',
    (WidgetTester tester) async {
      final store = InMemoryNutritionStore();
      final result = await pumpAddFoodPage(
        tester,
        localDb: _FakeLocalDb(),
        repository: _offlineRepository(store),
        initialItems: [
          (item: makeTestFood(name: 'Oatmeal', backendId: 1), grams: 120),
          (item: makeTestFood(name: 'Banana', backendId: 2), grams: 80),
        ],
      );

      // Staged before any interaction, at the source amounts (not the smart
      // defaults), with the log bar already up — "just press Log" is one tap.
      expect(find.text('ADDED ITEMS'), findsOneWidget);
      expect(find.text('2 items'), findsOneWidget);
      // 150 kcal/100g each: 120 g → 180 + 80 g → 120.
      expect(find.text('300 kcal total'), findsOneWidget);

      await tester.tap(find.text('Log to Breakfast'));
      await tester.pumpAndSettle();

      expect(store.entries, hasLength(2));
      expect(store.entries.values.map((e) => e.quantityG).toSet(), {
        120.0,
        80.0,
      });
      expect(await result, isTrue);
    },
  );

  testWidgets(
    'a food logged twice in the source meal seeds one merged staged row',
    (WidgetTester tester) async {
      final food = makeTestFood(name: 'Oatmeal', backendId: 1);
      await pumpAddFoodPage(
        tester,
        localDb: _FakeLocalDb(),
        repository: _offlineRepository(InMemoryNutritionStore()),
        initialItems: [(item: food, grams: 100), (item: food, grams: 50)],
      );

      // One row at the summed amount: staged items are keyed by food
      // identity, and two rows sharing a key would fight over every edit.
      expect(find.text('1 item'), findsOneWidget);
      expect(find.text('225 kcal total'), findsOneWidget);
    },
  );

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
    expect(find.text('ADDED ITEMS'), findsOneWidget);

    // The result card now reads as added; tapping it edits the staged amount
    // (no second copy). 'Oatmeal' appears twice now — staged tile first in
    // the column, result card last.
    final addedCard = find.text('Oatmeal').last;
    await tester.ensureVisible(addedCard);
    await tester.pumpAndSettle();
    await tester.tap(addedCard);
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget);

    // Removing from the sheet unstages it and the log bar disappears; the
    // Undo snackbar (KAN-39) brings the staged item back.
    await tester.tap(find.text('Remove from meal'));
    await tester.pumpAndSettle();
    expect(find.text('ADDED ITEMS'), findsNothing);
    expect(find.text('Log to Breakfast'), findsNothing);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('ADDED ITEMS'), findsOneWidget);
    expect(find.text('Log to Breakfast'), findsOneWidget);
  });

  testWidgets(
    'amount-sheet actions survive the staged entry being removed via the '
    'View Details flow while the sheet is open',
    (WidgetTester tester) async {
      // An offline-created override (no backendId → revert skips the API and
      // only touches the local DB) staged *after* another item, so its index
      // is the last slot — the slot that vanishes when the revert removes it.
      final override = FoodItem(
        localId: 1,
        source: customSource,
        externalId: 'cf-1',
        name: 'My Fixed Oatmeal',
        brands: '',
        kcal100g: 380,
        proteinG100g: 12,
        rawSourceJson: '{}',
        overridesBackendId: 99,
      );
      final localDb = _FakeLocalDb(
        recents: [
          makeTestFood(name: 'Banana'),
          override,
        ],
      );
      await pumpAddFoodPage(
        tester,
        localDb: localDb,
        repository: _offlineRepository(InMemoryNutritionStore()),
      );

      // Stage both, then open the editor on the override (staged index 1).
      await tester.ensureVisible(find.text('Banana', skipOffstage: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Banana'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.text('My Fixed Oatmeal', skipOffstage: false).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('My Fixed Oatmeal').last);
      await tester.pumpAndSettle();
      // Edit the staged tile (first of the two texts — staged column first,
      // result card last).
      await tester.ensureVisible(
        find.text('My Fixed Oatmeal', skipOffstage: false).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('My Fixed Oatmeal').first);
      await tester.pumpAndSettle();
      expect(find.text('Save changes'), findsOneWidget);

      // Sheet header → detail page → revert the override. onItemReverted
      // fires while the sheet is still open and drops the staged entry.
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('My Fixed Oatmeal'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FoodDetailPage), findsOneWidget);
      await tester.ensureVisible(
        find.text('Revert to original', skipOffstage: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revert to original'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revert'));
      await tester.pumpAndSettle();
      expect(localDb.deletedLocalIds, [1]);

      // Back on the sheet, ask to remove: the stored index (1) now points
      // past the end of the one-item list — this must be a no-op, not a
      // RangeError, and Banana must survive untouched.
      expect(find.text('Save changes'), findsOneWidget);
      await tester.tap(find.text('Remove from meal'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('ADDED ITEMS', skipOffstage: false), findsOneWidget);
      expect(find.text('1 item', skipOffstage: false), findsOneWidget);
      expect(find.text('Banana', skipOffstage: false), findsWidgets);
    },
  );

  testWidgets('swiping a staged item removes it with Undo (KAN-39)', (
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
    // No persistent remove button on the staged row (KAN-39).
    expect(find.byIcon(Icons.remove_circle), findsNothing);
    expect(find.byType(Dismissible), findsOneWidget);

    await tester.drag(find.byType(Dismissible), const Offset(-800, 0));
    await tester.pumpAndSettle();
    expect(find.text('ADDED ITEMS'), findsNothing);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('ADDED ITEMS'), findsOneWidget);
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

  testWidgets(
    'FatSecret search results are merged into the results list alongside '
    'local/backend/OFF',
    (WidgetTester tester) async {
      final fatsecret = _FakeFatSecretClient(
        searchResults: [
          makeFatSecretSearchHit(foodId: '1', name: 'Diner Burger'),
        ],
      );
      await pumpAddFoodPage(
        tester,
        localDb: _FakeLocalDb(),
        repository: _offlineRepository(InMemoryNutritionStore()),
        fatsecretApi: fatsecret,
      );

      await search(tester, 'burger');

      expect(find.text('Diner Burger', skipOffstage: false), findsOneWidget);
    },
  );

  testWidgets(
    'tapping a serving-less FatSecret result enriches it first (getFood) and '
    'stages it with the piece default',
    (WidgetTester tester) async {
      // FatSecret search never returns serving data; the full food does.
      final fatsecret = _FakeFatSecretClient(
        searchResults: [
          makeFatSecretSearchHit(
            foodId: '1',
            name: 'Diner Burger',
            description: 'Per 1 burger - Calories: 400kcal',
          ),
        ],
        foodsById: {
          '1': makeFatSecretDetail(
            foodId: '1',
            name: 'Diner Burger',
            metricGrams: 200,
            calories: 400,
            measurementDescription: 'burger',
          ),
        },
      );
      await pumpAddFoodPage(
        tester,
        localDb: _FakeLocalDb(),
        repository: _offlineRepository(InMemoryNutritionStore()),
        fatsecretApi: fatsecret,
      );

      await search(tester, 'burger');
      final card = find.text('Diner Burger', skipOffstage: false).first;
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();

      // Exactly one enrichment fetch, and the staged amount defaults to one
      // whole 200 g burger — the food's declared whole-portion calories
      // (400 kcal), normalized to 200 kcal/100g and back for the 200 g piece.
      expect(fatsecret.fetchedFoodIds, ['1']);
      expect(find.text('1 burger (200 g) • 400 kcal'), findsOneWidget);
    },
  );

  testWidgets(
    'a 401 during FatSecret enrich routes to onLogout — a dead session must '
    'not be dressed up as "no nutrition data"',
    (WidgetTester tester) async {
      final fatsecret = _FakeFatSecretClient(
        searchResults: [
          makeFatSecretSearchHit(
            foodId: '1',
            name: 'Diner Burger',
            description: 'Per 1 burger - Calories: 400kcal',
          ),
        ],
        // A 401 surfacing here means the interceptor's refresh already
        // failed — the session is dead for every backend call.
        getFoodError: ApiException('Session expired.', statusCode: 401),
      );
      var loggedOut = false;
      await pumpAddFoodPage(
        tester,
        localDb: _FakeLocalDb(),
        repository: _offlineRepository(InMemoryNutritionStore()),
        fatsecretApi: fatsecret,
        onLogout: () async => loggedOut = true,
      );

      await search(tester, 'burger');
      final card = find.text('Diner Burger', skipOffstage: false).first;
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();

      expect(fatsecret.fetchedFoodIds, ['1']);
      expect(loggedOut, isTrue);
    },
  );

  testWidgets(
    'a FatSecret item whose enrich finds no per-100g-mappable serving shows '
    'a snackbar and stages nothing (refuses a zero-calorie phantom)',
    (WidgetTester tester) async {
      final fatsecret = _FakeFatSecretClient(
        searchResults: [
          makeFatSecretSearchHit(
            foodId: '1',
            name: 'Mystery Item',
            description: 'Per 1 serving - Calories: 400kcal',
          ),
        ],
        // getFood returns a food with no usable metric mass on any serving —
        // FatSecretMapper.mapDetail returns null for this.
        foodsById: {
          '1': {
            'food_id': '1',
            'food_name': 'Mystery Item',
            'servings': {
              'serving': {
                'serving_description': '1 serving',
                'calories': '400',
              },
            },
          },
        },
      );
      await pumpAddFoodPage(
        tester,
        localDb: _FakeLocalDb(),
        repository: _offlineRepository(InMemoryNutritionStore()),
        fatsecretApi: fatsecret,
      );

      await search(tester, 'mystery');
      final card = find.text('Mystery Item', skipOffstage: false).first;
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();

      expect(fatsecret.fetchedFoodIds, ['1']);
      expect(
        find.text('No nutrition data available for this item.'),
        findsOneWidget,
      );
      expect(find.text('ADDED ITEMS'), findsNothing);
    },
  );

  testWidgets('the "Powered by FatSecret" attribution footer shows only when a '
      'FatSecret result is visible, never over the Recent Foods default view', (
    WidgetTester tester,
  ) async {
    final fatsecret = _FakeFatSecretClient(
      searchResults: [
        makeFatSecretSearchHit(foodId: '1', name: 'Diner Burger'),
      ],
    );
    await pumpAddFoodPage(
      tester,
      localDb: _FakeLocalDb(recents: [makeTestFood(name: 'Oatmeal')]),
      repository: _offlineRepository(InMemoryNutritionStore()),
      fatsecretApi: fatsecret,
    );

    // Recent Foods default view: no query, no FatSecret rows — no footer.
    expect(find.text('Oatmeal'), findsOneWidget);
    expect(find.text('Powered by FatSecret'), findsNothing);

    await search(tester, 'burger');

    expect(find.text('Diner Burger', skipOffstage: false), findsOneWidget);
    expect(
      find.text('Powered by FatSecret', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets(
    'no attribution footer when search results include no FatSecret rows',
    (WidgetTester tester) async {
      await pumpAddFoodPage(
        tester,
        localDb: _FakeLocalDb(recents: [makeTestFood(name: 'Oatmeal')]),
        repository: _offlineRepository(InMemoryNutritionStore()),
      );

      await search(tester, 'oatmeal');

      expect(find.text('Powered by FatSecret'), findsNothing);
    },
  );

  testWidgets(
    'retry after a mid-list submit failure only re-attempts the failed items',
    (WidgetTester tester) async {
      final localDb = _FakeLocalDb(
        recents: [
          makeTestFood(name: 'Apple', backendId: 1),
          makeTestFood(name: 'Banana', backendId: 2),
          makeTestFood(name: 'Cherry', backendId: 3),
        ],
      );
      final store = InMemoryNutritionStore();
      final repository = _FlakyCreateRepository(
        api: NutritionApiService(
          accessToken: 'test-token',
          dio: _deadNetworkDio(),
        ),
        store: store,
      )..failNextFor.add('Banana');
      final result = await pumpAddFoodPage(
        tester,
        localDb: localDb,
        repository: repository,
      );

      for (final name in ['Apple', 'Banana', 'Cherry']) {
        await tester.ensureVisible(find.text(name));
        await tester.pumpAndSettle();
        await tester.tap(find.text(name));
        await tester.pumpAndSettle();
      }
      expect(find.text('3 items'), findsOneWidget);

      await tester.tap(find.text('Log to Breakfast'));
      await tester.pumpAndSettle();

      // Apple was logged before Banana failed; the loop stopped there. Only
      // the failure and what follows it stay staged, and the banner names
      // the item that failed.
      expect(store.entries, hasLength(1));
      expect(find.text('2 items'), findsOneWidget);
      expect(find.textContaining('Could not log Banana'), findsOneWidget);

      // Retry re-attempts only Banana and Cherry — Apple is not duplicated.
      await tester.tap(find.text('Log to Breakfast'));
      await tester.pumpAndSettle();

      expect(store.entries, hasLength(3));
      expect(repository.createdFoods, ['Apple', 'Banana', 'Cherry']);
      expect(await result, isTrue);
    },
  );

  testWidgets('long-press on a catalog result opens the read-first detail page '
      'without staging or forking anything (KAN-35)', (
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
    await tester.longPress(find.text('Oatmeal'));
    await tester.pumpAndSettle();

    // Read-first detail page, not the fork-on-edit form.
    expect(find.byType(FoodDetailPage), findsOneWidget);
    expect(find.byType(CustomFoodPage), findsNothing);
    // The gesture mutated nothing: no staged item, no forked override.
    expect(localDb.upserted, isEmpty);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('ADDED ITEMS'), findsNothing);
  });

  testWidgets('long-press on your own custom food also opens the detail page, '
      'not the edit form directly', (WidgetTester tester) async {
    final custom = FoodItem(
      localId: 1,
      backendId: 7,
      source: customSource,
      externalId: 'cf-1',
      name: 'My Protein Shake',
      brands: '',
      kcal100g: 380,
      proteinG100g: 70,
      rawSourceJson: '{}',
    );
    await pumpAddFoodPage(
      tester,
      localDb: _FakeLocalDb(recents: [custom]),
      repository: _offlineRepository(InMemoryNutritionStore()),
    );

    await tester.ensureVisible(find.text('My Protein Shake'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('My Protein Shake'));
    await tester.pumpAndSettle();

    expect(find.byType(FoodDetailPage), findsOneWidget);
    expect(find.byType(CustomFoodPage), findsNothing);
  });

  testWidgets(
    'long-press on a serving-less OFF result enriches it before opening '
    'the detail page',
    (WidgetTester tester) async {
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
      await tester.longPress(card);
      await tester.pumpAndSettle();

      // Enriched exactly once, then pushed the detail page with the full
      // product (serving size present rather than sparse search data).
      expect(off.fetchedBarcodes, ['555']);
      expect(find.byType(FoodDetailPage), findsOneWidget);
      expect(find.text('30 g', skipOffstage: false), findsOneWidget);
    },
  );

  testWidgets(
    'long-press on an Added-items row opens the detail page for catalog '
    'foods too',
    (WidgetTester tester) async {
      final localDb = _FakeLocalDb(recents: [makeTestFood(name: 'Oatmeal')]);
      await pumpAddFoodPage(
        tester,
        localDb: localDb,
        repository: _offlineRepository(InMemoryNutritionStore()),
      );

      // Stage it with a tap, then long-press the staged tile (first of the
      // two 'Oatmeal' texts — result card is last in the column).
      await tester.ensureVisible(find.text('Oatmeal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oatmeal'));
      await tester.pumpAndSettle();
      final stagedTile = find.text('Oatmeal').first;
      await tester.longPress(stagedTile);
      await tester.pumpAndSettle();

      expect(find.byType(FoodDetailPage), findsOneWidget);

      // The staged item survived the round trip untouched.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('ADDED ITEMS'), findsOneWidget);
      expect(find.text('1 item'), findsOneWidget);
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

  testWidgets(
    'search bar stays pinned while the results grid scrolls (KAN-60)',
    (WidgetTester tester) async {
      // backendId null so each food keeps its own result key (the shared
      // default id would dedup them all into one card).
      final localDb = _FakeLocalDb(
        recents: [
          for (var i = 0; i < 30; i++)
            makeTestFood(name: 'Food $i', backendId: null),
        ],
      );
      await pumpAddFoodPage(
        tester,
        localDb: localDb,
        repository: _offlineRepository(InMemoryNutritionStore()),
      );

      expect(find.text('TOTAL ENERGY'), findsOneWidget);

      // Scroll deep into the grid: the summary scrolls away but the search
      // field stays reachable without scrolling back up.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();

      expect(find.text('TOTAL ENERGY'), findsNothing);
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
    },
  );

  testWidgets('result cards build lazily, not all at once (KAN-60)', (
    WidgetTester tester,
  ) async {
    // backendId null so each food keeps its own result key (the shared
    // default id would dedup them all into one card).
    final localDb = _FakeLocalDb(
      recents: [
        for (var i = 0; i < 30; i++)
          makeTestFood(name: 'Food $i', backendId: null),
      ],
    );
    await pumpAddFoodPage(
      tester,
      localDb: localDb,
      repository: _offlineRepository(InMemoryNutritionStore()),
    );

    // The first card is built; the far end of the list is not even offstage —
    // a virtualized sliver never instantiates it.
    expect(find.text('Food 0', skipOffstage: false), findsOneWidget);
    expect(find.text('Food 29', skipOffstage: false), findsNothing);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
    await tester.pumpAndSettle();
    expect(find.text('Food 29', skipOffstage: false), findsOneWidget);
  });

  testWidgets('log bar animates out instead of vanishing in one frame '
      '(KAN-60)', (WidgetTester tester) async {
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
    expect(find.text('Log to Breakfast'), findsOneWidget);

    // Unstage the only item: mid-transition the bar is still on screen,
    // after the ~200 ms switch it is gone.
    await tester.drag(find.byType(Dismissible), const Offset(-800, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Log to Breakfast'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Log to Breakfast'), findsNothing);
  });

  testWidgets(
    'add-food page and amount sheet survive max system text scale (KAN-40)',
    (WidgetTester tester) async {
      // Phone-sized viewport at the largest Android text scale; any RenderFlex
      // overflow fails the test via the reported FlutterError.
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);

      final localDb = _FakeLocalDb(recents: [makeTestFood(name: 'Oatmeal')]);
      await pumpAddFoodPage(
        tester,
        localDb: localDb,
        repository: _offlineRepository(InMemoryNutritionStore()),
      );

      // Stage a food: the summary bento (min-height cards) and the added
      // list now render with real values.
      await tester.ensureVisible(find.text('Oatmeal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oatmeal'));
      await tester.pumpAndSettle();
      expect(find.text('ADDED ITEMS'), findsOneWidget);

      // The staged tile is first in the column; tapping it opens the amount
      // sheet, whose kcal figure + macro pills must wrap rather than overflow.
      final stagedTile = find.text('Oatmeal').first;
      await tester.ensureVisible(stagedTile);
      await tester.pumpAndSettle();
      await tester.tap(stagedTile);
      await tester.pumpAndSettle();
      expect(find.text('Save changes'), findsOneWidget);
    },
  );
}
