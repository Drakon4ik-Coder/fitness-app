import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/nutrition_today_page.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';

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
}
