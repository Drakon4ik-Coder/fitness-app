import 'package:dio/dio.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/data/user_preferences.dart';
import 'package:fitness_app/features/nutrition/nutrition_today_page.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'in_memory_nutrition_store.dart';

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
                    'fat_g': 82, // over by 12  -> amber "over"
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
      // Sugars is over its 90 g target, a cautionary nutrient -> "over".
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
}
