import 'package:dio/dio.dart';
import 'package:fitness_app/features/nutrition/add_food_page.dart';
import 'package:fitness_app/features/nutrition/data/food_local_db.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/foods_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_local_store.dart';
import 'package:fitness_app/features/nutrition/data/off_client.dart';
import 'package:fitness_app/features/nutrition/data/off_rate_limiter.dart';
import 'package:fitness_app/features/nutrition/data/user_preferences.dart';
import 'package:fitness_app/features/nutrition/nutrition_today_page.dart';
import 'package:fitness_app/features/nutrition/widgets/meal_detail_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'in_memory_nutrition_store.dart';

/// Minimal in-memory catalog cache so the add-food page pushed from a meal
/// card doesn't reach sqflite's missing platform channel (KAN-36 tests).
class _FakeLocalDb extends FoodLocalDb {
  @override
  Future<List<FoodItem>> fetchRecentFoods({int limit = 20}) async => const [];

  @override
  Future<List<FoodItem>> fetchFavorites({int limit = 20}) async => const [];
}

class _FakeFoodsApi extends FoodsApiService {
  _FakeFoodsApi() : super(accessToken: 'test-token');

  @override
  Future<List<FoodItem>> typeahead(String query, {int limit = 10}) async =>
      const [];
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

Map<String, dynamic> _dayPayload({required String date, required num kcal}) {
  return {
    'date': date,
    'totals': {'kcal': kcal, 'protein_g': 0, 'carbs_g': 0, 'fat_g': 0},
    'meals': {'breakfast': [], 'lunch': [], 'dinner': [], 'snacks': []},
  };
}

String _todayKey() =>
    NutritionApiService.formatDate(DateUtils.dateOnly(DateTime.now()));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Nutrition Today page shows key sections', (
    WidgetTester tester,
  ) async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'date': '2024-01-01',
                'totals': {'kcal': 0, 'protein_g': 0, 'carbs_g': 0, 'fat_g': 0},
                'meals': {
                  'breakfast': [],
                  'lunch': [],
                  'dinner': [],
                  'snacks': [],
                },
              },
            ),
          );
        },
      ),
    );
    final nutritionApi = NutritionApiService(accessToken: 'token', dio: dio);
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: NutritionTodayPage(
          accessToken: 'token',
          onLogout: () async {},
          nutritionApi: nutritionApi,
          localStore: InMemoryNutritionStore(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('LEFT'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.text('Breakfast', skipOffstage: false), findsOneWidget);
  });

  testWidgets(
    'Nutrition Today page shows over-limit state when goals are exceeded',
    (WidgetTester tester) async {
      // Goals are hardcoded in the page: 2200 kcal, 150g protein, 260g carbs,
      // 70g fat. These totals push every one of them over the limit.
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'date': '2024-01-01',
                  'totals': {
                    'kcal': 2520, // over by 320
                    'protein_g': 170, // over by 20  -> green "✓"
                    'carbs_g': 275, // over by 15  -> neutral "over"
                    'fat_g': 82, // over by 12  -> neutral "over" (KAN-38)
                  },
                  'meals': {
                    'breakfast': [],
                    'lunch': [],
                    'dinner': [],
                    'snacks': [],
                  },
                },
              ),
            );
          },
        ),
      );
      final nutritionApi = NutritionApiService(accessToken: 'token', dio: dio);
      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: nutritionApi,
            localStore: InMemoryNutritionStore(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Calorie ring flips from "LEFT" to "OVER" and shows the signed overage.
      expect(find.text('OVER'), findsOneWidget);
      expect(find.text('LEFT'), findsNothing);
      expect(find.text('+320'), findsOneWidget);

      // Nutrient-aware macro over states.
      expect(find.text('+20g ✓'), findsOneWidget);
      expect(find.text('+15g over'), findsOneWidget);
      expect(find.text('+12g over'), findsOneWidget);
    },
  );

  testWidgets(
    'over-goal warning is opt-in: fat only goes amber once enabled (KAN-38)',
    (WidgetTester tester) async {
      Dio overFatDio() {
        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'date': '2024-01-01',
                    'totals': {
                      'kcal': 1500,
                      'protein_g': 50,
                      'carbs_g': 100,
                      'fat_g': 82, // over the 70 g default by 12
                    },
                    'meals': {
                      'breakfast': [],
                      'lunch': [],
                      'dinner': [],
                      'snacks': [],
                    },
                  },
                ),
              );
            },
          ),
        );
        return dio;
      }

      Color? fatOverColor() =>
          tester.widget<Text>(find.text('+12g over')).style?.color;

      // Fresh account: no warn opt-ins -> neutral over treatment.
      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: NutritionApiService(
              accessToken: 'token',
              dio: overFatDio(),
            ),
            localStore: InMemoryNutritionStore(),
            preferences: const UserPreferences(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(fatOverColor(), LuminaHealthColors.onSurfaceVariant);

      // Same day with "warn on fat" enabled -> amber.
      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: NutritionApiService(
              accessToken: 'token',
              dio: overFatDio(),
            ),
            localStore: InMemoryNutritionStore(),
            preferences: const UserPreferences(warnNutrients: ['fat']),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(fatOverColor(), LuminaHealthColors.warning);
    },
  );

  testWidgets(
    'renders the user\'s focus nutrients with their units and over states',
    (WidgetTester tester) async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'date': '2024-01-01',
                  'totals': {
                    'kcal': 1200,
                    'protein_g': 80,
                    'carbs_g': 120,
                    'fat_g': 40,
                  },
                  'nutrients': {
                    'fiber': {'amount': 12, 'unit': 'g'},
                    'sugars': {'amount': 95, 'unit': 'g'},
                    'vitamin_c': {'amount': 30, 'unit': 'mg'},
                  },
                  'meals': {
                    'breakfast': [],
                    'lunch': [],
                    'dinner': [],
                    'snacks': [],
                  },
                },
              ),
            );
          },
        ),
      );
      final nutritionApi = NutritionApiService(accessToken: 'token', dio: dio);
      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: nutritionApi,
            localStore: InMemoryNutritionStore(),
            preferences: const UserPreferences(
              focusNutrients: ['fiber', 'sugars', 'sodium', 'vitamin_c'],
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // The picked four replace the classic macro trio, in the picked order.
      expect(find.text('FIBER'), findsOneWidget);
      expect(find.text('SUGARS'), findsOneWidget);
      expect(find.text('SODIUM'), findsOneWidget);
      expect(find.text('VITAMIN C'), findsOneWidget);
      expect(find.text('PROTEIN'), findsNothing);

      // Fiber: 12 of 30 g.
      expect(find.text('12g'), findsOneWidget);
      expect(find.text('18g left'), findsOneWidget);
      // Sugars is over its 90 g target -> neutral "over" (warnings are
      // opt-in per KAN-38).
      expect(find.text('+5g over'), findsOneWidget);
      // Sodium has no server data on an empty day -> plain zero, mg unit.
      expect(find.text('0 mg'), findsOneWidget);
      expect(find.text('2300 mg left'), findsOneWidget);
      // Vitamin C: 30 of 80 mg.
      expect(find.text('50 mg left'), findsOneWidget);
    },
  );

  testWidgets(
    'shows cached day offline when the network fails (no error banner)',
    (WidgetTester tester) async {
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
      final nutritionApi = NutritionApiService(accessToken: 'token', dio: dio);
      // A day synced in an earlier session: seeded marker + entry-level rows.
      final store = InMemoryNutritionStore(
        seedPayloads: {_todayKey(): _dayPayload(date: _todayKey(), kcal: 1500)},
      );
      store.entries['cached-uuid'] = makeStoredEntry(
        uuid: 'cached-uuid',
        quantityG: 1000,
        kcal: 1500,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: nutritionApi,
            localStore: store,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The locally known day is rendered (1500 kcal eaten) and the failed
      // sync is swallowed rather than shown as an error.
      expect(find.text('1500'), findsOneWidget);
      expect(find.text('Unable to load nutrition data.'), findsNothing);
    },
  );

  testWidgets(
    'shows the waiting-to-sync chip while offline writes are queued (KAN-56)',
    (WidgetTester tester) async {
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
      final nutritionApi = NutritionApiService(accessToken: 'token', dio: dio);
      // A previously seeded day plus an entry logged offline: its create op
      // is still queued in the outbox.
      final store = InMemoryNutritionStore(
        seedPayloads: {_todayKey(): _dayPayload(date: _todayKey(), kcal: 150)},
      );
      store.entries['offline-uuid'] = makeStoredEntry(
        uuid: 'offline-uuid',
        serverId: null,
        pending: true,
      );
      await store.enqueueOp(
        kind: OutboxOp.create,
        entryUuid: 'offline-uuid',
        payload: const {'food_item_id': 7},
        queuedAt: DateTime.now().toUtc(),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: nutritionApi,
            localStore: store,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pendingSyncChip')), findsOneWidget);
      expect(find.text('1 change waiting to sync'), findsOneWidget);
    },
  );

  testWidgets('the sync chip is absent when the outbox is empty', (
    WidgetTester tester,
  ) async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: _dayPayload(date: _todayKey(), kcal: 500),
            ),
          );
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: NutritionTodayPage(
          accessToken: 'token',
          onLogout: () async {},
          nutritionApi: NutritionApiService(accessToken: 'token', dio: dio),
          localStore: InMemoryNutritionStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pendingSyncChip')), findsNothing);
  });

  testWidgets(
    'failed first load shows Retry on the error banner and it recovers',
    (WidgetTester tester) async {
      var failRequests = true;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (failRequests) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                ),
              );
              return;
            }
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: _dayPayload(date: _todayKey(), kcal: 1200),
              ),
            );
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: NutritionApiService(accessToken: 'token', dio: dio),
            localStore: InMemoryNutritionStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Nothing cached for the day, so the failure surfaces with a way out.
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('1200'), findsNothing);

      failRequests = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Retry'), findsNothing);
      expect(find.text('1200'), findsOneWidget);
    },
  );

  testWidgets('pull-to-refresh re-syncs the day', (WidgetTester tester) async {
    var requestCount = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestCount++;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: _dayPayload(date: _todayKey(), kcal: 900),
            ),
          );
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: NutritionTodayPage(
          accessToken: 'token',
          onLogout: () async {},
          nutritionApi: NutritionApiService(accessToken: 'token', dio: dio),
          localStore: InMemoryNutritionStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final before = requestCount;
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 400),
      1000,
    );
    await tester.pumpAndSettle();

    expect(requestCount, greaterThan(before));
  });

  testWidgets(
    'hero labels the add-food CTA and merges the kcal stat for a11y',
    (WidgetTester tester) async {
      final handle = tester.ensureSemantics();
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: _dayPayload(date: _todayKey(), kcal: 700),
              ),
            );
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: NutritionApiService(accessToken: 'token', dio: dio),
            localStore: InMemoryNutritionStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The primary CTA announces itself instead of a bare "button".
      expect(find.byTooltip('Add food'), findsOneWidget);
      // The ring center reads as one stat, not "1500" / "LEFT" fragments.
      expect(
        find.bySemanticsLabel(RegExp(r'^\d+ kilocalories left$')),
        findsOneWidget,
      );
      handle.dispose();
    },
  );

  testWidgets('first open full-fetches the day and seeds the local store', (
    WidgetTester tester,
  ) async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: _dayPayload(date: _todayKey(), kcal: 2000),
            ),
          );
        },
      ),
    );
    final nutritionApi = NutritionApiService(accessToken: 'token', dio: dio);
    final store = InMemoryNutritionStore();

    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: NutritionTodayPage(
          accessToken: 'token',
          onLogout: () async {},
          nutritionApi: nutritionApi,
          localStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The first open of a day full-fetches the server view and seeds the
    // local store so later refreshes can be cheap delta pulls.
    expect(find.text('2000'), findsOneWidget);
    expect(store.payloadWrites, contains(_todayKey()));
  });

  testWidgets(
    'pinned date bar stays visible on scroll and Today chip returns to today',
    (WidgetTester tester) async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: _dayPayload(date: _todayKey(), kcal: 0),
              ),
            );
          },
        ),
      );
      final nutritionApi = NutritionApiService(accessToken: 'token', dio: dio);
      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: nutritionApi,
            localStore: InMemoryNutritionStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // On today: no Today chip, and the next-day chevron is disabled.
      expect(find.byKey(const Key('todayChip')), findsNothing);
      final nextButton = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('Next day'),
          matching: find.byType(IconButton),
        ),
      );
      expect(nextButton.onPressed, isNull);

      // Step back a day: label flips and the Today chip appears.
      await tester.tap(find.byTooltip('Previous day'));
      await tester.pumpAndSettle();
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.byKey(const Key('todayChip')), findsOneWidget);

      // Scroll the content away: the date bar stays pinned near the top.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.text('Yesterday'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Yesterday')).dy, lessThan(60));

      // The chip returns to today and disappears once there.
      await tester.tap(find.byKey(const Key('todayChip')));
      await tester.pumpAndSettle();
      expect(find.text('Today'), findsOneWidget);
      expect(find.byKey(const Key('todayChip')), findsNothing);
    },
  );

  testWidgets('empty meal card shows a "+" and opens add-food with that meal '
      'preselected (KAN-36)', (WidgetTester tester) async {
    // Tall viewport so all four meal cards are onstage and tappable.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: _dayPayload(date: _todayKey(), kcal: 0),
            ),
          );
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: NutritionTodayPage(
          accessToken: 'token',
          onLogout: () async {},
          nutritionApi: NutritionApiService(accessToken: 'token', dio: dio),
          localStore: InMemoryNutritionStore(),
          localDb: _FakeLocalDb(),
          foodsApi: _FakeFoodsApi(),
          offClient: _FakeOffClient(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Every empty card advertises "add", not "navigate".
    expect(find.byIcon(Icons.add_circle_outline), findsNWidgets(4));

    await tester.tap(find.text('Lunch'));
    await tester.pumpAndSettle();

    // Landed on add-food with Lunch already selected (the meal selector
    // tile is the only 'Lunch' text on that page).
    expect(find.byType(AddFoodPage), findsOneWidget);
    expect(find.text('Lunch'), findsOneWidget);
  });

  testWidgets(
    'non-empty meal card keeps the chevron and opens the meal detail sheet',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'date': _todayKey(),
                  'totals': {
                    'kcal': 150,
                    'protein_g': 5,
                    'carbs_g': 27,
                    'fat_g': 3,
                  },
                  'meals': {
                    'breakfast': [],
                    'lunch': [
                      {
                        'id': 1,
                        'client_uuid': 'uuid-1',
                        'meal_type': 'lunch',
                        'consumed_at': '${_todayKey()}T12:00:00Z',
                        'quantity_g': 100,
                        'kcal': 150,
                        'updated_at': '${_todayKey()}T12:00:00Z',
                        'food_item': {
                          'id': 7,
                          'name': 'Oatmeal',
                          'kcal_100g': 150,
                        },
                      },
                    ],
                    'dinner': [],
                    'snacks': [],
                  },
                },
              ),
            );
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: NutritionApiService(accessToken: 'token', dio: dio),
            localStore: InMemoryNutritionStore(),
            localDb: _FakeLocalDb(),
            foodsApi: _FakeFoodsApi(),
            offClient: _FakeOffClient(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Only the three empty meals flip to "+"; the logged one keeps its
      // chevron.
      expect(find.byIcon(Icons.add_circle_outline), findsNWidgets(3));
      final lunchCard = find
          .ancestor(of: find.text('Oatmeal'), matching: find.byType(InkWell))
          .first;
      expect(
        find.descendant(
          of: lunchCard,
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Lunch'));
      await tester.pumpAndSettle();

      expect(find.byType(MealDetailSheet), findsOneWidget);
      expect(find.byType(AddFoodPage), findsNothing);
    },
  );

  testWidgets(
    'informational text sits on labelSmall (11px) and estimate status is not '
    'italic (KAN-40)',
    (WidgetTester tester) async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'date': _todayKey(),
                  // Under-goal totals so every focus tile renders the
                  // "…g left" status line.
                  'totals': {
                    'kcal': 1200,
                    'protein_g': 100,
                    'carbs_g': 130,
                    'fat_g': 35,
                  },
                  'meals': {
                    'breakfast': [],
                    'lunch': [],
                    'dinner': [],
                    'snacks': [],
                  },
                },
              ),
            );
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: NutritionApiService(accessToken: 'token', dio: dio),
            localStore: InMemoryNutritionStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      TextStyle styleOf(Finder finder) => tester.widget<Text>(finder).style!;

      // Stat labels and focus-tile value/status text are informational and
      // must not drop below labelSmall's 11px; only decorative micro-labels
      // (the SYMBIO wordmark, section headers) may.
      expect(styleOf(find.text('EATEN')).fontSize, greaterThanOrEqualTo(11));
      final status = styleOf(find.textContaining('g left').first);
      expect(status.fontSize, greaterThanOrEqualTo(11));
      expect(status.fontStyle, isNot(FontStyle.italic));
    },
  );

  group('copy previous day (KAN-51)', () {
    /// Routes the three calls the copy flow makes: entry creates echo the
    /// request as a server entry, deletes ack with 204, everything else gets
    /// an empty day/sync payload.
    Dio copyDio(List<Map<String, dynamic>> createBodies) {
      var nextId = 100;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.method == 'POST' &&
                options.path.endsWith('/nutrition/entries')) {
              final body = (options.data as Map).cast<String, dynamic>();
              createBodies.add(body);
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 201,
                  data: {
                    'id': nextId++,
                    'client_uuid': body['client_uuid'],
                    'meal_type': body['meal_type'],
                    'consumed_at': body['consumed_at'],
                    'quantity_g': body['quantity_g'],
                    'kcal': 180,
                    'updated_at': body['consumed_at'],
                    'food_item': {
                      'id': 7,
                      'name': 'Test Food',
                      'kcal_100g': 150,
                    },
                  },
                ),
              );
              return;
            }
            if (options.method == 'DELETE') {
              handler.resolve(
                Response(requestOptions: options, statusCode: 204),
              );
              return;
            }
            if (options.path.contains('/entries/sync')) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'entries': [], 'next_cursor': '', 'has_more': false},
                ),
              );
              return;
            }
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: _dayPayload(date: _todayKey(), kcal: 0),
              ),
            );
          },
        ),
      );
      return dio;
    }

    /// A store that already knows yesterday: seeded, with one breakfast entry.
    InMemoryNutritionStore storeWithYesterdayBreakfast() {
      final now = DateTime.now();
      final yesterday = DateTime(now.year, now.month, now.day - 1);
      final yesterdayKey = NutritionApiService.formatDate(yesterday);
      final store = InMemoryNutritionStore(
        seedPayloads: {
          yesterdayKey: _dayPayload(date: yesterdayKey, kcal: 180),
        },
      );
      store.entries['y-1'] = makeStoredEntry(
        uuid: 'y-1',
        serverId: 11,
        mealType: 'breakfast',
        consumedAt: DateTime(yesterday.year, yesterday.month, yesterday.day, 8),
        quantityG: 120,
        kcal: 180,
      );
      return store;
    }

    Widget app(Dio dio, InMemoryNutritionStore store) {
      return MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: NutritionTodayPage(
          accessToken: 'token',
          onLogout: () async {},
          nutritionApi: NutritionApiService(accessToken: 'token', dio: dio),
          localStore: store,
        ),
      );
    }

    testWidgets('empty meal offers the shortcut only when yesterday has it', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(app(copyDio([]), storeWithYesterdayBreakfast()));
      await tester.pumpAndSettle();

      // Only breakfast — the meal yesterday actually had — gets the shortcut.
      expect(find.byKey(const Key('copyPrevious-breakfast')), findsOneWidget);
      expect(find.text('Copy from yesterday'), findsOneWidget);
      expect(find.byKey(const Key('copyPrevious-lunch')), findsNothing);
    });

    testWidgets('shortcut is absent when nothing is known about yesterday', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(app(copyDio([]), InMemoryNutritionStore()));
      await tester.pumpAndSettle();

      expect(find.text('Copy from yesterday'), findsNothing);
    });

    testWidgets('one tap re-logs the meal as new entries, Undo removes them', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final createBodies = <Map<String, dynamic>>[];
      final store = storeWithYesterdayBreakfast();
      await tester.pumpWidget(app(copyDio(createBodies), store));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('copyPrevious-breakfast')));
      await tester.pumpAndSettle();

      // Same food and amount, but a brand-new client identity (KAN-28: the
      // uuid is the entry's identity for life — a copy must never reuse it).
      expect(createBodies, hasLength(1));
      expect(createBodies.single['food_item_id'], 7);
      expect(createBodies.single['meal_type'], 'breakfast');
      expect(createBodies.single['quantity_g'], 120);
      expect(createBodies.single['client_uuid'], isNot('y-1'));

      // The copy is on today's breakfast card and the shortcut is gone.
      expect(find.text('Test Food'), findsOneWidget);
      expect(find.byKey(const Key('copyPrevious-breakfast')), findsNothing);
      expect(find.text('Copied 1 food'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.text('Test Food'), findsNothing);
      expect(find.byKey(const Key('copyPrevious-breakfast')), findsOneWidget);
    });
  });

  testWidgets(
    'today page survives max system text scale without overflow (KAN-40)',
    (WidgetTester tester) async {
      // Phone-sized viewport at the largest Android text scale; any RenderFlex
      // overflow fails the test via the reported FlutterError.
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);

      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'date': _todayKey(),
                  // Over-goal totals produce the longest status strings
                  // ("+320 kcal over" beats "50g left").
                  'totals': {
                    'kcal': 2520,
                    'protein_g': 170,
                    'carbs_g': 275,
                    'fat_g': 82,
                  },
                  'meals': {
                    'breakfast': [],
                    'lunch': [
                      {
                        'id': 1,
                        'client_uuid': 'uuid-1',
                        'meal_type': 'lunch',
                        'consumed_at': '${_todayKey()}T12:00:00Z',
                        'quantity_g': 100,
                        'kcal': 150,
                        'updated_at': '${_todayKey()}T12:00:00Z',
                        'food_item': {
                          'id': 7,
                          'name': 'Oatmeal',
                          'kcal_100g': 150,
                        },
                      },
                    ],
                    'dinner': [],
                    'snacks': [],
                  },
                },
              ),
            );
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: NutritionApiService(accessToken: 'token', dio: dio),
            localStore: InMemoryNutritionStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll to the bottom so the meal cards lay out too.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1600));
      await tester.pumpAndSettle();
    },
  );
}
