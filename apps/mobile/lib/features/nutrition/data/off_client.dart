import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/environment.dart';

class OffException implements Exception {
  OffException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OffProductResponse {
  OffProductResponse({
    required this.product,
    required this.rawJson,
  });

  final Map<String, dynamic> product;
  final String rawJson;
}

class OffClient {
  OffClient({Dio? dio, String? userAgent})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: _baseUrl,
                headers: {
                  'User-Agent': userAgent ?? EnvironmentConfig.offUserAgent,
                },
              ),
            );

  static const String _baseUrl = 'https://world.openfoodfacts.org';
  static const List<String> _fields = [
    'code',
    'product_name',
    'product_name_en',
    'generic_name',
    'brands',
    'serving_size',
    'image_url',
    'image_front_url',
    'image_ingredients_url',
    'image_nutrition_url',
    'nutriments',
    'lang',
  ];

  final Dio _dio;

  Future<OffProductResponse?> fetchProduct(String barcode) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/v2/product/$barcode',
        queryParameters: {'fields': _fields.join(',')},
      );
      final data = response.data;
      if (data == null) {
        return null;
      }
      final status = data['status'];
      if (status != 1) {
        return null;
      }
      final product = data['product'];
      if (product is Map<String, dynamic>) {
        return OffProductResponse(
          product: product,
          rawJson: jsonEncode(data),
        );
      }
      return null;
    } on DioException catch (error) {
      throw OffException(error.message ?? 'Unable to fetch from OFF.');
    } catch (_) {
      throw OffException('Unable to fetch from OFF.');
    }
  }

  Future<List<OffProductResponse>> searchProducts(
    String query, {
    int pageSize = 12,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/v2/search',
        queryParameters: {
          'search_terms': query,
          'fields': _fields.join(','),
          'page_size': pageSize,
        },
      );
      final data = response.data;
      if (data == null) {
        return [];
      }
      final products = data['products'];
      if (products is! List) {
        return [];
      }
      return products
          .whereType<Map<String, dynamic>>()
          .map(
            (product) => OffProductResponse(
              product: product,
              rawJson: jsonEncode({'product': product}),
            ),
          )
          .toList();
    } on DioException catch (error) {
      throw OffException(error.message ?? 'Unable to search OFF.');
    } catch (_) {
      throw OffException('Unable to search OFF.');
    }
  }
}
