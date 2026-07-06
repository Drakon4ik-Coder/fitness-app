import 'package:dio/dio.dart';
import 'package:fitness_app/features/nutrition/data/preferences_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fetch parses units, calorie goal and nutrient goals', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'weight_unit': 'lb',
              'height_unit': 'in',
              'energy_unit': 'kj',
              'daily_calorie_goal': 2400,
              'nutrient_goals': {'protein': 150.0, 'vitamin_c': 90},
            },
          ),
        ),
      ),
    );

    final prefs = await PreferencesApiService(
      accessToken: 'token',
      dio: dio,
    ).fetch();

    expect(prefs.weightUnit, 'lb');
    expect(prefs.energyUnit, 'kj');
    expect(prefs.calorieGoal, 2400);
    expect(prefs.nutrientGoals['protein'], closeTo(150, 1e-9));
    expect(prefs.nutrientGoals['vitamin_c'], closeTo(90, 1e-9));
  });

  test('update PATCHes only the provided fields', () async {
    late RequestOptions captured;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured = options;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'weight_unit': 'kg',
                'height_unit': 'cm',
                'energy_unit': 'kcal',
                'daily_calorie_goal': 2000,
                'nutrient_goals': {'protein': 120.0},
              },
            ),
          );
        },
      ),
    );

    final result = await PreferencesApiService(
      accessToken: 'token',
      dio: dio,
    ).update(calorieGoal: 2000, nutrientGoals: {'protein': 120});

    expect(captured.method, 'PATCH');
    expect(captured.path, '/api/v1/preferences/');
    final body = captured.data as Map<String, dynamic>;
    // Only the fields we passed are sent — untouched prefs stay server-side.
    expect(body.keys, containsAll(['daily_calorie_goal', 'nutrient_goals']));
    expect(body.containsKey('weight_unit'), isFalse);
    expect(body['nutrient_goals'], {'protein': 120});
    expect(result.calorieGoal, 2000);
  });
}
