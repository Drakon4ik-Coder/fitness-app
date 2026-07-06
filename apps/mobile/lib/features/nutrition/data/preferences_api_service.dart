import 'package:dio/dio.dart';

import '../../../core/auth_interceptor.dart';
import '../../../core/environment.dart';
import 'api_exceptions.dart';
import 'user_preferences.dart';

/// Reads and updates the signed-in user's [UserPreferences] via
/// `/api/v1/preferences/`. Mirrors [NutritionApiService]'s Dio + auth setup.
class PreferencesApiService {
  PreferencesApiService({
    required String accessToken,
    AuthInterceptor? authInterceptor,
    Dio? dio,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: EnvironmentConfig.apiBaseUrl,
               headers: {'Authorization': 'Bearer $accessToken'},
             ),
           ) {
    authInterceptor?.attachTo(_dio);
  }

  final Dio _dio;

  void updateToken(String accessToken) {
    _dio.options.headers['Authorization'] = 'Bearer $accessToken';
  }

  Future<UserPreferences> fetch() {
    return mapApiErrors('Unable to load preferences.', () async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/v1/preferences/',
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw ApiException('Unexpected response from server.');
      }
      return UserPreferences.fromJson(data);
    });
  }

  /// Persists a partial update. Only the provided fields are sent, so untouched
  /// preferences are left as-is. Returns the server's updated snapshot.
  Future<UserPreferences> update({
    String? weightUnit,
    String? heightUnit,
    String? energyUnit,
    int? calorieGoal,
    Map<String, double>? nutrientGoals,
    List<String>? focusNutrients,
  }) async {
    final body = <String, dynamic>{
      if (weightUnit != null) 'weight_unit': weightUnit,
      if (heightUnit != null) 'height_unit': heightUnit,
      if (energyUnit != null) 'energy_unit': energyUnit,
      if (calorieGoal != null) 'daily_calorie_goal': calorieGoal,
      if (nutrientGoals != null) 'nutrient_goals': nutrientGoals,
      if (focusNutrients != null) 'focus_nutrients': focusNutrients,
    };
    return mapApiErrors('Unable to save preferences.', () async {
      final response = await _dio.patch<Map<String, dynamic>>(
        '/api/v1/preferences/',
        data: body,
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw ApiException('Unexpected response from server.');
      }
      return UserPreferences.fromJson(data);
    });
  }
}
