import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_day_cache.dart';
import 'package:fitness_app/features/nutrition/nutrition_today_page.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';

/// In-memory stand-in for [NutritionDayCache] so widget tests don't touch
/// sqflite / path_provider platform channels.
class _InMemoryDayCache implements NutritionDayCache {
  _InMemoryDayCache([Map<String, Map<String, dynamic>>? seed])
      : _store = {...?seed};

  final Map<String, Map<String, dynamic>> _store;
  final List<String> writes = [];
  bool cleared = false;

  @override
  Future<Map<String, dynamic>?> read(String dateKey) async => _store[dateKey];

  @override
  Future<void> write(String dateKey, Map<String, dynamic> payload) async {
    _store[dateKey] = payload;
    writes.add(dateKey);
  }

  @override
  Future<void> clear() async {
    _store.clear();
    cleared = true;
  }

  @override
  Future<void> close() async {}
}

Map<String, dynamic> _dayPayload({
  required String date,
  required num kcal,
}) {
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

  testWidgets('Nutrition Today page shows key sections',
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
                  'kcal': 0,
                  'protein_g': 0,
                  'carbs_g': 0,
                  'fat_g': 0,
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
    final nutritionApi =
        NutritionApiService(accessToken: 'token', dio: dio);
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: NutritionTodayPage(
          accessToken: 'token',
          onLogout: () async {},
          nutritionApi: nutritionApi,
          dayCache: _InMemoryDayCache(),
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
            dayCache: _InMemoryDayCache(),
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
    'shows cached day offline when the network fails (no error banner)',
    (WidgetTester tester) async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(requestOptions: options, type: DioExceptionType.connectionError),
            );
          },
        ),
      );
      final nutritionApi = NutritionApiService(accessToken: 'token', dio: dio);
      final cache = _InMemoryDayCache({
        _todayKey(): _dayPayload(date: _todayKey(), kcal: 1500),
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: nutritionApi,
            dayCache: cache,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The cached day is rendered (1500 kcal eaten) and the failed refresh is
      // swallowed rather than shown as an error.
      expect(find.text('1500'), findsOneWidget);
      expect(find.text('Unable to load nutrition data.'), findsNothing);
    },
  );

  testWidgets(
    'revalidates over the cached day and writes the fresh copy back',
    (WidgetTester tester) async {
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
      final cache = _InMemoryDayCache({
        _todayKey(): _dayPayload(date: _todayKey(), kcal: 1000),
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaHealthTheme.dark(),
          home: NutritionTodayPage(
            accessToken: 'token',
            onLogout: () async {},
            nutritionApi: nutritionApi,
            dayCache: cache,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Network value wins over the stale cached one, and the cache is refreshed.
      expect(find.text('2000'), findsOneWidget);
      expect(find.text('1000'), findsNothing);
      expect(cache.writes, contains(_todayKey()));
    },
  );
}
