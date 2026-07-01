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

/// A learned typical time for one meal type, derived from the user's history.
/// [typicalHour] and [halfWidth] are fractional hours (e.g. 12.5 == 12:30).
class MealTimeStat {
  const MealTimeStat({
    required this.typicalHour,
    required this.halfWidth,
    required this.sampleCount,
  });

  final double typicalHour;
  final double halfWidth;
  final int sampleCount;
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
    return parseDayLog(await fetchDayRaw(date));
  }

  /// Fetches the raw `/day` payload without parsing. The page caches this map
  /// verbatim (stale-while-revalidate) and parses it via [parseDayLog], so the
  /// cached bytes are exactly what the server sent — no lossy round-trip.
  Future<Map<String, dynamic>> fetchDayRaw(DateTime date) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/v1/nutrition/day',
        queryParameters: {'date': formatDate(date)},
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw ApiException('Unexpected response from server.');
      }
      return data;
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

  /// Per-meal typical times learned from the user's history. Meals without
  /// enough history are simply absent from the map (caller uses its defaults).
  Future<Map<String, MealTimeStat>> fetchMealTimes() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/v1/nutrition/meal-times',
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw ApiException('Unexpected response from server.');
      }
      final raw = data['meal_times'] as Map<String, dynamic>? ?? {};
      final result = <String, MealTimeStat>{};
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is! Map<String, dynamic>) continue;
        final typical = parseNullableDouble(value['typical_hour']);
        if (typical == null) continue;
        result[entry.key] = MealTimeStat(
          typicalHour: typical,
          halfWidth: parseNullableDouble(value['half_width']) ?? 2.0,
          sampleCount: (value['sample_count'] as num?)?.toInt() ?? 0,
        );
      }
      return result;
    } on DioException catch (error) {
      throw ApiException(
        'Unable to load meal times.',
        statusCode: error.response?.statusCode,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException('Unable to load meal times.');
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
          // Send the true UTC instant (Z-suffixed). The server stores UTC and
          // converts back to the user's reported timezone for day grouping and
          // meal-time stats — so callers pass a local DateTime and we normalize.
          if (consumedAt != null)
            'consumed_at': consumedAt.toUtc().toIso8601String(),
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

  /// Parses a raw `/day` payload (from the network or the local cache) into a
  /// [NutritionDayLog]. Public so the page can parse cached maps directly.
  NutritionDayLog parseDayLog(Map<String, dynamic> data) {
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

  /// `YYYY-MM-DD` for the day endpoint. Also the cache key, so both the request
  /// and its cached copy are keyed identically.
  static String formatDate(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}
