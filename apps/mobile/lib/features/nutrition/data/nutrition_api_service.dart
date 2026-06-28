import 'package:dio/dio.dart';

import '../../../core/auth_interceptor.dart';
import '../../../core/environment.dart';
import 'api_exceptions.dart';
import 'food_models.dart';

class NutritionTotals {
  const NutritionTotals({
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
  });

  final double kcal;
  final double proteinG;
  final double carbsG;
  final double fatG;
}

class NutritionEntry {
  const NutritionEntry({
    required this.id,
    required this.mealType,
    required this.consumedAt,
    required this.quantityG,
    required this.kcal,
    required this.foodItem,
  });

  final int id;
  final String mealType;
  final DateTime consumedAt;
  final double quantityG;
  final double kcal;
  final FoodItem foodItem;
}

class NutritionDayLog {
  NutritionDayLog({
    required this.date,
    required this.totals,
    required this.meals,
  });

  final DateTime date;
  final NutritionTotals totals;
  final Map<String, List<NutritionEntry>> meals;
}

class NutritionApiService {
  NutritionApiService({
    required String accessToken,
    AuthInterceptor? authInterceptor,
    Dio? dio,
  }) : _dio = dio ??
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

  Future<NutritionDayLog> fetchDay(DateTime date) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/v1/nutrition/day',
        queryParameters: {'date': _formatDate(date)},
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw ApiException('Unexpected response from server.');
      }
      return _parseDayLog(data);
    } on DioException catch (error) {
      throw ApiException(
        'Unable to load nutrition data.',
        statusCode: error.response?.statusCode,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException('Unable to load nutrition data.');
    }
  }

  Future<NutritionEntry> createEntry({
    required int foodItemId,
    required String mealType,
    required double quantityG,
    DateTime? consumedAt,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/nutrition/entries',
        data: {
          'food_item_id': foodItemId,
          'meal_type': mealType,
          'quantity_g': quantityG,
          if (consumedAt != null) 'consumed_at': consumedAt.toIso8601String(),
        },
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw ApiException('Unexpected response from server.');
      }
      return _parseEntry(data);
    } on DioException catch (error) {
      throw ApiException(
        'Unable to add entry.',
        statusCode: error.response?.statusCode,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException('Unable to add entry.');
    }
  }

  Future<NutritionEntry> updateEntry({
    required int entryId,
    double? quantityG,
    String? mealType,
  }) async {
    try {
      final response = await _dio.patch<Map<String, dynamic>>(
        '/api/v1/nutrition/entries/$entryId',
        data: {
          if (quantityG != null) 'quantity_g': quantityG,
          if (mealType != null) 'meal_type': mealType,
        },
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw ApiException('Unexpected response from server.');
      }
      return _parseEntry(data);
    } on DioException catch (error) {
      throw ApiException(
        'Unable to update entry.',
        statusCode: error.response?.statusCode,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException('Unable to update entry.');
    }
  }

  Future<void> deleteEntry(int entryId) async {
    try {
      await _dio.delete<void>('/api/v1/nutrition/entries/$entryId');
    } on DioException catch (error) {
      throw ApiException(
        'Unable to delete entry.',
        statusCode: error.response?.statusCode,
      );
    }
  }

  NutritionDayLog _parseDayLog(Map<String, dynamic> data) {
    final totalsRaw = data['totals'] as Map<String, dynamic>? ?? {};
    final totals = NutritionTotals(
      kcal: parseNullableDouble(totalsRaw['kcal']) ?? 0,
      proteinG: parseNullableDouble(totalsRaw['protein_g']) ?? 0,
      carbsG: parseNullableDouble(totalsRaw['carbs_g']) ?? 0,
      fatG: parseNullableDouble(totalsRaw['fat_g']) ?? 0,
    );
    final mealsRaw = data['meals'] as Map<String, dynamic>? ?? {};
    final Map<String, List<NutritionEntry>> meals = {};
    for (final entry in mealsRaw.entries) {
      final list = entry.value;
      if (list is List) {
        meals[entry.key] = list
            .whereType<Map<String, dynamic>>()
            .map(_parseEntry)
            .toList();
      }
    }
    return NutritionDayLog(
      date: DateTime.parse(data['date'] as String),
      totals: totals,
      meals: meals,
    );
  }

  NutritionEntry _parseEntry(Map<String, dynamic> data) {
    final foodItemRaw = data['food_item'] as Map<String, dynamic>? ?? {};
    // Use the detailed mapper so each logged entry carries full per-100g macros
    // and a derived piece/serving descriptor — the meal-details editor reuses the
    // same amount sheet (stepper, unit toggle, live macro preview) as add-food.
    final foodItem = FoodItem.fromBackendDetail(foodItemRaw);
    return NutritionEntry(
      id: data['id'] as int,
      mealType: data['meal_type'] as String? ?? '',
      consumedAt: DateTime.parse(data['consumed_at'] as String),
      quantityG: parseNullableDouble(data['quantity_g']) ?? 0,
      kcal: parseNullableDouble(data['kcal']) ?? 0,
      foodItem: foodItem,
    );
  }

  String _formatDate(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}
