import 'package:dio/dio.dart';

import '../../../core/environment.dart';
import 'api_exceptions.dart';
import 'food_models.dart';

class FoodCheckResult {
  const FoodCheckResult({
    required this.exists,
    required this.upToDate,
    required this.foodItemId,
    required this.imagesOk,
  });

  final bool exists;
  final bool upToDate;
  final int? foodItemId;
  final bool imagesOk;
}

class FoodsApiService {
  FoodsApiService({
    required String accessToken,
    Dio? dio,
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: EnvironmentConfig.apiBaseUrl,
                headers: {'Authorization': 'Bearer $accessToken'},
              ),
            );

  final Dio _dio;

  void updateToken(String accessToken) {
    _dio.options.headers['Authorization'] = 'Bearer $accessToken';
  }

  Future<List<FoodItem>> typeahead(String query, {int limit = 10}) async {
    try {
      final response = await _dio.get<List<dynamic>>(
        '/api/v1/foods/typeahead',
        queryParameters: {
          'q': query,
          'limit': limit,
        },
      );
      final data = response.data;
      if (data == null) {
        return [];
      }
      return data
          .whereType<Map<String, dynamic>>()
          .map(FoodItem.fromBackendSummary)
          .toList();
    } on DioException catch (error) {
      throw ApiException(
        'Unable to search foods.',
        statusCode: error.response?.statusCode,
      );
    } catch (_) {
      throw ApiException('Unable to search foods.');
    }
  }

  Future<FoodItem> ingestFood(FoodItem item) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/foods/ingest',
        data: item.toBackendPayload(),
      );
      final data = response.data;
      if (data is Map<String, dynamic>) {
        return FoodItem.fromBackendDetail(data);
      }
      throw ApiException('Unexpected response from server.');
    } on DioException catch (error) {
      throw ApiException(
        'Unable to save food.',
        statusCode: error.response?.statusCode,
      );
    } catch (_) {
      throw ApiException('Unable to save food.');
    }
  }

  Future<FoodCheckResult> checkFood({
    required String source,
    required String externalId,
    required String contentHash,
    String? imageSignature,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/foods/check',
        data: {
          'source': source,
          'external_id': externalId,
          'content_hash': contentHash,
          if (imageSignature != null && imageSignature.trim().isNotEmpty)
            'image_signature': imageSignature,
        },
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw ApiException('Unexpected response from server.');
      }
      return FoodCheckResult(
        exists: data['exists'] == true,
        upToDate: data['up_to_date'] == true,
        foodItemId: data['food_item_id'] as int?,
        imagesOk: data['images_ok'] == true,
      );
    } on DioException catch (error) {
      throw ApiException(
        'Unable to check food status.',
        statusCode: error.response?.statusCode,
      );
    } catch (_) {
      throw ApiException('Unable to check food status.');
    }
  }
}
