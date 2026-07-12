import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/app_log.dart';
import '../../../core/auth_interceptor.dart';
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

class FoodIngestResult {
  const FoodIngestResult({required this.item, required this.imagesOk});
  final FoodItem item;
  final bool imagesOk;
}

class FoodsApiService {
  FoodsApiService({
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

  Future<List<FoodItem>> typeahead(String query, {int limit = 10}) {
    return mapApiErrors('Unable to search foods.', () async {
      final response = await _dio.get<List<dynamic>>(
        '/api/v1/foods/typeahead',
        queryParameters: {'q': query, 'limit': limit},
      );
      final data = response.data;
      if (data == null) {
        return <FoodItem>[];
      }
      return data
          .whereType<Map<String, dynamic>>()
          .map(FoodItem.fromBackendSummary)
          .toList();
    });
  }

  Future<FoodIngestResult> ingestFood(FoodItem item) {
    return mapApiErrors('Unable to save food.', () async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/foods/ingest',
        data: item.toBackendPayload(),
      );
      final data = response.data;
      if (data is Map<String, dynamic>) {
        return FoodIngestResult(
          item: FoodItem.fromBackendDetail(data),
          imagesOk: data['images_ok'] == true,
        );
      }
      throw ApiException('Unexpected response from server.');
    });
  }

  /// Owner-scoped upsert for a user's own food: re-posting the same
  /// `external_id` updates it in place, so create, edit, and offline re-sync
  /// are all this one call.
  Future<FoodItem> upsertCustomFood(FoodItem item) {
    return mapApiErrors('Unable to save food.', () async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/foods/custom',
        data: item.toCustomPayload(),
      );
      final data = response.data;
      if (data is Map<String, dynamic>) {
        return FoodItem.fromBackendDetail(data);
      }
      throw ApiException('Unexpected response from server.');
    });
  }

  /// Soft-deletes one of the caller's custom foods. A 404 (already gone or
  /// never synced) counts as success.
  Future<void> deleteCustomFood(int backendId) {
    return mapApiErrors('Unable to delete food.', () async {
      try {
        await _dio.delete<void>('/api/v1/foods/custom/$backendId');
      } on DioException catch (error) {
        if (error.response?.statusCode == 404) return;
        rethrow;
      }
    });
  }

  Future<FoodCheckResult> checkFood({
    required String source,
    required String externalId,
    required String contentHash,
    String? imageSignature,
  }) {
    return mapApiErrors('Unable to check food status.', () async {
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
    });
  }

  Future<FoodItem?> uploadFoodImages({
    required int foodItemId,
    required Uint8List bytes,
    required String contentType,
    String? imageSignature,
  }) async {
    try {
      final formData = FormData.fromMap({
        'image': MultipartFile.fromBytes(
          bytes,
          filename: 'image.jpg',
          contentType: DioMediaType.parse(contentType),
        ),
        if (imageSignature != null && imageSignature.trim().isNotEmpty)
          'image_signature': imageSignature,
      });
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/foods/$foodItemId/images',
        data: formData,
      );
      final data = response.data;
      if (data is Map<String, dynamic>) {
        return FoodItem.fromBackendDetail(data);
      }
      return null;
    } catch (error, stackTrace) {
      // Best-effort by design: images are re-uploadable, so a failure only
      // means the food keeps its previous image state. Still worth a trace.
      logError('uploadFoodImages', error, stackTrace);
      return null;
    }
  }
}
