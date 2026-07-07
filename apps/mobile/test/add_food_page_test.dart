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

/// Backend foods API that never leaves the process: typeahead is empty, and
/// anything that would mutate server state fails the test loudly.
class _FakeFoodsApi extends FoodsApiService {
  _FakeFoodsApi() : super(accessToken: 'test-token');

  @override
  Future<List<FoodItem>> typeahead(String query, {int limit = 10}) async =>
      const [];

  @override
  Future<FoodItem> upsertCustomFood(FoodItem item) async =>
      throw StateError('unexpected upsertCustomFood');

  @override
  Future<FoodIngestResult> ingestFood(FoodItem item) async =>
      throw StateError('unexpected ingestFood');
}

class _FakeOffClient extends OffClient {
  _FakeOffClient() : super(dio: Dio(), rateLimiter: OffRateLimiter());

  @override
  Future<List<OffProductResponse>> searchProducts(
    String query, {
    int pageSize = 10,
    String? categoryTag,
    CancelToken? cancelToken,
  }) async => const [];

  @override
  Future<OffProductResponse?> fetchProduct(String barcode) async => null;
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
                    foodsApi: _FakeFoodsApi(),
                    repository: repository,
                    offClient: _FakeOffClient(),
                    onLogout: () async {},
                    selectedDate: DateUtils.dateOnly(DateTime.now()),
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
}
