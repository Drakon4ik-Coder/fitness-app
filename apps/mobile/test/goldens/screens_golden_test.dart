@Tags(['golden'])
library;

import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/core/auth_storage.dart';
import 'package:fitness_app/features/login_page.dart';
import 'package:fitness_app/features/nutrition/add_food_page.dart';
import 'package:fitness_app/features/nutrition/data/food_local_db.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/foods_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_repository.dart';
import 'package:fitness_app/features/nutrition/data/off_client.dart';
import 'package:fitness_app/features/nutrition/data/off_rate_limiter.dart';
import 'package:fitness_app/features/nutrition/data/user_preferences.dart';
import 'package:fitness_app/features/nutrition/live_search_controller.dart';
import 'package:fitness_app/features/nutrition/nutrition_today_page.dart';
import 'package:fitness_app/features/nutrition/widgets/amount_sheet.dart';
import 'package:fitness_app/features/nutrition/widgets/meal_detail_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../in_memory_nutrition_store.dart';

// Screenshot tests for the main screens (KAN-129). They catch visual
// regressions the behavioral tests can't: a refactor that keeps every widget
// findable but shifts, clips or recolors it.
//
// Regenerate after an intended UI change by adding the `update-goldens` label
// to the PR (CI renders them on Linux and uploads the PNGs as an artifact),
// or locally on Linux with:
//   flutter test --update-goldens test/goldens

/// Phone-sized surface (390x844 logical, 2x) so layouts render as on device.
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

Widget _app(Widget home) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: LuminaHealthTheme.dark(),
  home: home,
);

FoodItem _food(
  String name, {
  required double kcal,
  double protein = 0,
  double carbs = 0,
  double fat = 0,
  int? backendId,
  double? piece,
  String? pieceUnit,
}) => FoodItem(
  backendId: backendId,
  source: offSource,
  externalId: name,
  name: name,
  brands: 'Symbio Farms',
  kcal100g: kcal,
  proteinG100g: protein,
  carbsG100g: carbs,
  fatG100g: fat,
  gramsPerPiece: piece,
  pieceUnit: pieceUnit,
  rawSourceJson: '{}',
  nutrimentsJson: {
    'proteins_100g': protein,
    'carbohydrates_100g': carbs,
    'fat_100g': fat,
    'fiber_100g': 3,
  },
);

final _oats = _food('Rolled oats', kcal: 379, protein: 13, carbs: 68, fat: 7);
final _banana = _food('Banana', kcal: 89, protein: 1, carbs: 23, fat: 0.3);
final _yogurt = _food('Greek yogurt', kcal: 97, protein: 9, carbs: 4, fat: 5);
final _egg = _food(
  'Free-range egg',
  kcal: 143,
  protein: 13,
  fat: 10,
  piece: 50,
  pieceUnit: 'egg',
);

class _FakeLocalDb extends FoodLocalDb {
  _FakeLocalDb({this.recents = const []});

  final List<FoodItem> recents;

  @override
  Future<List<FoodItem>> fetchRecentFoods({int limit = 20}) async => recents;

  @override
  Future<List<FoodItem>> fetchFavorites({int limit = 20}) async => const [];

  @override
  Future<List<FoodItem>> searchFoods(String query, {int limit = 20}) async =>
      const [];
}

class _FakeFoodsApi extends FoodsApiService {
  _FakeFoodsApi({this.results = const []}) : super(accessToken: 'token');

  final List<FoodItem> results;

  @override
  Future<List<FoodItem>> typeahead(String query, {int limit = 10}) async =>
      results;
}

class _FakeOffClient extends OffClient {
  _FakeOffClient({this.searchError})
    : super(dio: Dio(), rateLimiter: OffRateLimiter());

  final Object? searchError;

  @override
  Future<List<OffProductResponse>> searchProducts(
    String query, {
    int pageSize = 10,
    String? categoryTag,
    CancelToken? cancelToken,
  }) async {
    if (searchError != null) throw searchError!;
    return const [];
  }
}

Map<String, dynamic> _entryJson(
  int id,
  String meal,
  FoodItem food,
  double grams,
  String date,
) => {
  'id': id,
  'client_uuid': 'golden-$id',
  'meal_type': meal,
  'consumed_at': '${date}T08:00:00Z',
  'quantity_g': grams,
  'kcal': food.kcal100g! * grams / 100,
  'updated_at': '${date}T08:00:00Z',
  'food_item': {
    'id': id + 100,
    'name': food.name,
    'brands': food.brands,
    'kcal_100g': food.kcal100g,
    'protein_g_100g': food.proteinG100g,
    'carbs_g_100g': food.carbsG100g,
    'fat_g_100g': food.fatG100g,
  },
};

/// Serves every `/day` request with [meals] and empty sync pages.
Dio _dayDio(Map<String, List<Map<String, dynamic>>> Function(String) meals) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final date = options.queryParameters['date'] as String? ?? '2026-01-01';
        final logged = meals(date);
        // Totals are server-computed from the entries, like the real /day.
        double sum(String key) => logged.values
            .expand((list) => list)
            .fold(
              0.0,
              (total, entry) =>
                  total +
                  ((entry['food_item'] as Map)[key] as num) *
                      (entry['quantity_g'] as num) /
                      100,
            );
        final data = options.path.endsWith('/entries/sync')
            ? {'entries': [], 'next_cursor': 'c1', 'has_more': false}
            : options.path.endsWith('/day')
            ? {
                'date': date,
                'totals': {
                  'kcal': sum('kcal_100g'),
                  'protein_g': sum('protein_g_100g'),
                  'carbs_g': sum('carbs_g_100g'),
                  'fat_g': sum('fat_g_100g'),
                },
                'meals': {
                  'breakfast': [],
                  'lunch': [],
                  'dinner': [],
                  'snacks': [],
                  ...logged,
                },
              }
            : <String, dynamic>{};
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: data),
        );
      },
    ),
  );
  return dio;
}

Widget _todayPage(
  Dio dio, {
  UserPreferences? preferences,
  InMemoryNutritionStore? store,
}) => _app(
  NutritionTodayPage(
    accessToken: 'token',
    onLogout: () async {},
    nutritionApi: NutritionApiService(accessToken: 'token', dio: dio),
    localStore: store ?? InMemoryNutritionStore(),
    localDb: _FakeLocalDb(),
    foodsApi: _FakeFoodsApi(),
    offClient: _FakeOffClient(),
    preferences: preferences,
  ),
);

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pump(
    LiveSearchController.defaultDebounce + const Duration(milliseconds: 50),
  );
  await tester.pumpAndSettle();
}

Widget _addFoodPage({
  List<StagedFood> initialItems = const [],
  List<FoodItem> searchResults = const [],
  Object? offSearchError,
}) => _app(
  AddFoodPage(
    localDb: _FakeLocalDb(recents: [_oats, _banana, _yogurt, _egg]),
    foodsApi: _FakeFoodsApi(results: searchResults),
    repository: NutritionRepository(
      api: NutritionApiService(accessToken: 'token', dio: _dayDio((_) => {})),
      store: InMemoryNutritionStore(),
    ),
    offClient: _FakeOffClient(searchError: offSearchError),
    onLogout: () async {},
    selectedDate: DateUtils.dateOnly(DateTime.now()),
    initialMeal: MealType.breakfast,
    initialItems: initialItems,
  ),
);

void main() {
  testWidgets('today: empty day', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_todayPage(_dayDio((_) => {})));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/today_empty.png'),
    );
  });

  Future<void> pumpLoggedDay(WidgetTester tester) async {
    final dio = _dayDio(
      (date) => {
        'breakfast': [
          _entryJson(1, 'breakfast', _oats, 80, date),
          _entryJson(2, 'breakfast', _banana, 120, date),
        ],
        'lunch': [_entryJson(3, 'lunch', _yogurt, 500, date)],
      },
    );
    await tester.pumpWidget(
      _todayPage(
        dio,
        // A lowered fat goal the user opted to be warned about (KAN-38).
        preferences: const UserPreferences(
          nutrientGoals: {'fat': 30},
          warnNutrients: ['fat'],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('today: logged day with an over-goal warning', (tester) async {
    _phone(tester);
    await pumpLoggedDay(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/today_logged.png'),
    );
  });

  testWidgets('today: meal detail sheet', (tester) async {
    _phone(tester);
    await pumpLoggedDay(tester);
    await tester.tap(find.text('Breakfast'));
    await tester.pumpAndSettle();
    expect(find.byType(MealDetailSheet), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/today_meal_sheet.png'),
    );
  });

  testWidgets('add food: recents', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_addFoodPage());
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/add_food_recents.png'),
    );
  });

  Future<void> pumpStaged(WidgetTester tester) async {
    await tester.pumpWidget(
      _addFoodPage(
        initialItems: [(item: _oats, grams: 60), (item: _egg, grams: 100)],
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('add food: staged items and log bar', (tester) async {
    _phone(tester);
    await pumpStaged(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/add_food_staged.png'),
    );
  });

  testWidgets('add food: amount sheet for a piece food', (tester) async {
    _phone(tester);
    await pumpStaged(tester);
    await tester.tap(find.text('Free-range egg').first);
    await tester.pumpAndSettle();
    expect(find.byType(AmountSheet), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/amount_sheet.png'),
    );
  });

  testWidgets('today: pending-sync chip', (tester) async {
    _phone(tester);
    final store = InMemoryNutritionStore();
    // Two offline edits still queued (KAN-56).
    for (final uuid in ['golden-1', 'golden-2']) {
      await store.enqueueOp(
        kind: 'update',
        entryUuid: uuid,
        payload: const {'quantity_g': 90},
        queuedAt: DateTime.utc(2026, 1, 1),
      );
    }
    final dio = _dayDio(
      (date) => {
        'breakfast': [_entryJson(1, 'breakfast', _oats, 80, date)],
      },
    );
    // Replay fails offline, so the ops stay queued and the chip shows.
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) => options.method == 'PATCH'
            ? handler.reject(
                DioException.connectionError(
                  requestOptions: options,
                  reason: 'offline',
                ),
              )
            : handler.next(options),
      ),
    );
    await tester.pumpWidget(_todayPage(dio, store: store));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pendingSyncChip')), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/today_pending_sync.png'),
    );
  });

  testWidgets('today: max text scale (KAN-40)', (tester) async {
    _phone(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await pumpLoggedDay(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/today_text_scale_2x.png'),
    );
  });

  testWidgets('add food: search results', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _addFoodPage(
        searchResults: [
          _food('Greek yogurt, plain', kcal: 97, protein: 9, carbs: 4, fat: 5),
          _food(
            'Greek yogurt, honey',
            kcal: 120,
            protein: 7,
            carbs: 15,
            fat: 4,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await _search(tester, 'greek');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/add_food_search.png'),
    );
  });

  testWidgets('add food: rate-limit banner', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _addFoodPage(
        offSearchError: OffRateLimitException(const Duration(seconds: 30)),
      ),
    );
    await tester.pumpAndSettle();
    await _search(tester, 'oat');
    expect(find.textContaining('resuming in 30s'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/add_food_rate_limited.png'),
    );
  });

  testWidgets('login', (tester) async {
    _phone(tester);
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(
      _app(
        LoginPage(
          authService: AuthService(dio: Dio()),
          authStorage: AuthStorage(),
          onLoggedIn: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/login.png'),
    );
  });
}
