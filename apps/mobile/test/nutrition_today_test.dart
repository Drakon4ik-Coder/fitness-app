import 'package:dio/dio.dart';
import 'package:fitness_app/features/nutrition/add_food_page.dart';
import 'package:fitness_app/features/nutrition/data/api_exceptions.dart';
import 'package:fitness_app/features/nutrition/data/food_local_db.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/foods_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_local_store.dart';
import 'package:fitness_app/features/nutrition/data/off_client.dart';
import 'package:fitness_app/features/nutrition/data/off_rate_limiter.dart';
import 'package:fitness_app/features/nutrition/data/user_preferences.dart';
import 'package:fitness_app/features/nutrition/nutrition_today_page.dart';
import 'package:fitness_app/features/nutrition/widgets/amount_sheet.dart'
    show FoodImage, mealTypeAccent, mealTypeIcon;
import 'package:fitness_app/features/nutrition/widgets/meal_detail_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'in_memory_nutrition_store.dart';

/// Minimal in-memory catalog cache so the add-food page pushed from a meal
/// card doesn't reach sqflite's missing platform channel (KAN-36 tests).
class _FakeLocalDb extends FoodLocalDb {
  int _nextLocalId = 1;

  @override
  Future<List<FoodItem>> fetchRecentFoods({int limit = 20}) async => const [];

  @override
  Future<List<FoodItem>> fetchFavorites({int limit = 20}) async => const [];

  // The duplicate-meal flow submits through the add-food page, which
  // persists each food locally and touches the recents ordering.
  @override
  Future<FoodItem> upsertFood(FoodItem item) async =>
      item.localId == null ? item.copyWith(localId: _nextLocalId++) : item;

  @override
  Future<void> updateLastUsed(
    int localId,
    DateTime usedAt,
    double loggedGrams,
  ) async {}
}

class _FakeFoodsApi extends FoodsApiService {
  _FakeFoodsApi() : super(accessToken: 'test-token');

  @override
  Future<List<FoodItem>> typeahead(String query, {int limit = 10}) async =>
      const [];
}

/// Rejects every custom-food upsert, forcing a duplicate submit that stages
/// an unsynced custom food to fail mid-list after earlier items logged.
class _RejectingFoodsApi extends _FakeFoodsApi {
  @override
  Future<FoodItem> upsertCustomFood(FoodItem item) async =>
      throw ApiException('Rejected by server.');
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
    // The eaten figure sums per-entry rounded kcal (KAN-99), so a non-empty
    // day carries a matching entry — like real server payloads, where totals
    // are computed from the entries.
    'meals': {
      'breakfast': [],
      'lunch': [if (kcal != 0) _entryPayload(date: date, kcal: kcal)],
      'dinner': [],
      'snacks': [],
    },
  };
}

Map<String, dynamic> _entryPayload({
  required String date,
  required num kcal,
  int id = 1,
  String mealType = 'lunch',
}) {
  return {
    'id': id,
    'client_uuid': 'seed-$mealType-$id',
    'meal_type': mealType,
    'consumed_at': '${date}T12:00:00Z',
    'quantity_g': 100,
    'kcal': kcal,
    'food_item': {'id': 7, 'name': 'Seed Food', 'kcal_100g': kcal},
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
                    'lunch': [_entryPayload(date: '2024-01-01', kcal: 2520)],
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
    'eaten kcal equals the sum of the meal cards for fractional entries '
    '(KAN-99)',
    (WidgetTester tester) async {
      // Three 100.4-kcal entries: the raw sum (301.2) rounds to 301, but each
      // visible row rounds to 100 — every surface must agree on 300 (round
      // per entry, then sum), or the ring disagrees with the meal cards.
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
                    'kcal': 301.2,
                    'protein_g': 0,
                    'carbs_g': 0,
                    'fat_g': 0,
                  },
                  'meals': {
                    'breakfast': [
                      _entryPayload(
                        date: _todayKey(),
                        kcal: 100.4,
                        id: 1,
                        mealType: 'breakfast',
                      ),
                      _entryPayload(
                        date: _todayKey(),
                        kcal: 100.4,
                        id: 2,
                        mealType: 'breakfast',
                      ),
                    ],
                    'lunch': [
                      _entryPayload(
                        date: _todayKey(),
                        kcal: 100.4,
                        id: 3,
                        mealType: 'lunch',
                      ),
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

      // Ring: 200 (breakfast) + 100 (lunch), not totals.kcal rounded to 301.
      expect(find.text('300'), findsOneWidget);
      expect(find.text('301'), findsNothing);
      expect(find.text('200 kcal', skipOffstage: false), findsOneWidget);
      expect(find.text('100 kcal', skipOffstage: false), findsOneWidget);
    },
  );

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

  testWidgets('meal cards tint their icons with per-meal accents (KAN-3)', (
    WidgetTester tester,
  ) async {
    // Tall viewport so all four meal cards are onstage.
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
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Each card's icon carries its own meal accent, and no two meals share
    // one — color backs up the icon+label pair without ever colliding.
    for (final meal in MealType.values) {
      final icon = tester.widget<Icon>(find.byIcon(mealTypeIcon(meal)));
      expect(
        icon.color,
        mealTypeAccent(meal),
        reason: '${meal.label} icon should use its meal accent',
      );
    }
    final accents = MealType.values.map(mealTypeAccent).toSet();
    expect(accents, hasLength(MealType.values.length));
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
    'meal-card thumbnail goes through FoodImage (placeholder + retry + '
    'downscaled decode, KAN-60)',
    (WidgetTester tester) async {
      // Tall viewport so the meal cards are on screen (they sit below the
      // summary sections at the default 600px height).
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
                          'image_url': 'https://example.com/oatmeal.jpg',
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

      // The lunch card's 64px thumbnail renders via FoodImage — the raw
      // Image.network (no loadingBuilder, full-size decode) is gone. The
      // test HTTP client fails the fetch, which FoodImage absorbs into its
      // retry state instead of an uncaught exception. Only the lunch card
      // carries an image URL, so exactly one FoodImage is on the page.
      expect(find.byType(FoodImage), findsOneWidget);
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

  /// Routes the three calls the copy/duplicate flows make: entry creates echo
  /// the request as a server entry, deletes ack with 204, everything else gets
  /// an empty day/sync payload. [createDelay] holds the create response
  /// open so a test can act while a copy is still in flight.
  Dio copyDio(
    List<Map<String, dynamic>> createBodies, {
    Duration? createDelay,
  }) {
    var nextId = 100;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'POST' &&
              options.path.endsWith('/nutrition/entries')) {
            final body = (options.data as Map).cast<String, dynamic>();
            createBodies.add(body);
            void respond() => handler.resolve(
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
                  'food_item': {'id': 7, 'name': 'Test Food', 'kcal_100g': 150},
                },
              ),
            );
            if (createDelay != null) {
              Future<void>.delayed(createDelay, respond);
            } else {
              respond();
            }
            return;
          }
          if (options.method == 'DELETE') {
            handler.resolve(Response(requestOptions: options, statusCode: 204));
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
      seedPayloads: {yesterdayKey: _dayPayload(date: yesterdayKey, kcal: 180)},
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

  group('copy previous day (KAN-51)', () {
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

    testWidgets('rapid double tap copies the meal only once', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final createBodies = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        app(
          // Hold the create open so the second tap lands mid-copy — the
          // real-world double-tap window.
          copyDio(createBodies, createDelay: const Duration(milliseconds: 300)),
          storeWithYesterdayBreakfast(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('copyPrevious-breakfast')));
      // No pump between taps: the stale frame still shows the button, so
      // this exercises the in-flight guard rather than the rebuild.
      await tester.tap(find.byKey(const Key('copyPrevious-breakfast')));

      // Once the rebuild lands the shortcut is hidden for the whole copy.
      await tester.pump();
      expect(find.byKey(const Key('copyPrevious-breakfast')), findsNothing);

      // Release the held create (pumpAndSettle alone never advances the
      // clock while no frame is scheduled) and let the copy finish.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      // A copy mints fresh uuids, so a duplicate request would double the
      // meal — only the first tap may reach the repository.
      expect(createBodies, hasLength(1));
      expect(find.text('Copied 1 food'), findsOneWidget);
    });
  });

  group('duplicate meal', () {
    testWidgets(
      'duplicating a past meal stages it into add-food, logs to today, and '
      'jumps back to today',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final createBodies = <Map<String, dynamic>>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaHealthTheme.dark(),
            home: NutritionTodayPage(
              accessToken: 'token',
              onLogout: () async {},
              nutritionApi: NutritionApiService(
                accessToken: 'token',
                dio: copyDio(createBodies),
              ),
              localStore: storeWithYesterdayBreakfast(),
              localDb: _FakeLocalDb(),
              foodsApi: _FakeFoodsApi(),
              offClient: _FakeOffClient(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Browse to yesterday and open its logged breakfast.
        await tester.tap(find.byTooltip('Previous day'));
        await tester.pumpAndSettle();
        expect(find.text('Yesterday'), findsOneWidget);
        await tester.tap(find.text('Breakfast'));
        await tester.pumpAndSettle();

        // Duplicate closes the sheet and lands on add-food with the meal's
        // foods pre-staged at their logged amounts — nothing written yet.
        await tester.tap(find.byKey(const Key('duplicateMeal')));
        await tester.pumpAndSettle();
        expect(find.byType(AddFoodPage), findsOneWidget);
        expect(find.text('ADDED ITEMS'), findsOneWidget);
        expect(find.text('1 item'), findsOneWidget);
        expect(createBodies, isEmpty);

        await tester.tap(find.text('Log to Breakfast'));
        await tester.pumpAndSettle();

        // Same food and amount, fresh entry, consumed *today* (the duplicate
        // targets today no matter which day was being browsed).
        expect(createBodies, hasLength(1));
        expect(createBodies.single['food_item_id'], 7);
        expect(createBodies.single['meal_type'], 'breakfast');
        expect(createBodies.single['quantity_g'], 120);
        expect(createBodies.single['client_uuid'], isNot('y-1'));
        final consumedAt = DateTime.parse(
          createBodies.single['consumed_at'] as String,
        ).toLocal();
        expect(DateUtils.isSameDay(consumedAt, DateTime.now()), isTrue);

        // The page jumped from yesterday back to today to show the result.
        expect(find.text('Today'), findsOneWidget);
        expect(find.text('Meal logged'), findsOneWidget);
        expect(find.text('Test Food'), findsOneWidget);
      },
    );

    testWidgets('backing out of a duplicate logs nothing and stays put', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final createBodies = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: NutritionApiService(
              accessToken: 'token',
              dio: copyDio(createBodies),
            ),
            localStore: storeWithYesterdayBreakfast(),
            localDb: _FakeLocalDb(),
            foodsApi: _FakeFoodsApi(),
            offClient: _FakeOffClient(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Previous day'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Breakfast'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('duplicateMeal')));
      await tester.pumpAndSettle();
      expect(find.byType(AddFoodPage), findsOneWidget);

      // Abandoning the staged copy must not log anything or yank the user
      // off the day they were browsing.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(createBodies, isEmpty);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Meal logged'), findsNothing);
    });

    testWidgets(
      'backing out after a partially failed duplicate still jumps to today',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        // Yesterday's breakfast has a second food: an unsynced custom food
        // whose upsert the server rejects, so the duplicate submit logs the
        // first entry to today and then fails mid-list.
        final store = storeWithYesterdayBreakfast();
        final now = DateTime.now();
        final yesterday = DateTime(now.year, now.month, now.day - 1);
        store.entries['y-2'] = makeStoredEntry(
          uuid: 'y-2',
          serverId: 12,
          mealType: 'breakfast',
          consumedAt: DateTime(
            yesterday.year,
            yesterday.month,
            yesterday.day,
            9,
          ),
          quantityG: 50,
          kcal: 90,
          food: FoodItem(
            source: customSource,
            externalId: 'custom-broken',
            name: 'Broken Custom',
            brands: '',
            kcal100g: 180,
            proteinG100g: 5,
            carbsG100g: 10,
            fatG100g: 2,
            rawSourceJson: '{}',
          ),
        );

        final createBodies = <Map<String, dynamic>>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaHealthTheme.dark(),
            home: NutritionTodayPage(
              accessToken: 'token',
              onLogout: () async {},
              nutritionApi: NutritionApiService(
                accessToken: 'token',
                dio: copyDio(createBodies),
              ),
              localStore: store,
              localDb: _FakeLocalDb(),
              foodsApi: _RejectingFoodsApi(),
              offClient: _FakeOffClient(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Previous day'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Breakfast'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('duplicateMeal')));
        await tester.pumpAndSettle();
        expect(find.byType(AddFoodPage), findsOneWidget);

        await tester.tap(find.text('Log to Breakfast'));
        await tester.pumpAndSettle();

        // First food logged, then the custom upsert failed: the page stays
        // open reporting the failure, with the first entry already created.
        expect(createBodies, hasLength(1));
        expect(find.byType(AddFoodPage), findsOneWidget);
        expect(find.textContaining('Could not log'), findsOneWidget);

        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();

        // No clean submit, but an entry landed on today — the page must
        // jump there so the logged copy isn't off-screen. No success snack.
        expect(find.text('Today'), findsOneWidget);
        expect(find.text('Test Food'), findsOneWidget);
        expect(find.text('Meal logged'), findsNothing);
      },
    );
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
