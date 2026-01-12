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
  OffClient({
    Dio? dio,
    String? userAgent,
    String? country,
  })  : _countryTag = _normalizeCountryTag(
          country ?? EnvironmentConfig.offCountry,
        ),
        _userAgent = userAgent ?? EnvironmentConfig.offUserAgent,
        _dio = dio ??
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
    'categories_tags',
    'image_url',
    'image_front_url',
    'image_front_small_url',
    'image_ingredients_url',
    'image_nutrition_url',
    'nutriments',
    'lang',
  ];

  static String _normalizeCountryTag(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) {
      return '';
    }
    if (normalized.startsWith('en:')) {
      return normalized;
    }
    if (normalized == 'uk' || normalized == 'gb') {
      return 'en:united-kingdom';
    }
    return normalized.replaceAll(' ', '-');
  }

  final Dio _dio;
  final String _countryTag;
  final String _userAgent;

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
    String? categoryTag,
  }) async {
    try {
      return await _searchCgi(
        query,
        pageSize: pageSize,
        categoryTag: categoryTag,
      );
    } on DioException {
      try {
        return await _searchV2(
          query,
          pageSize: pageSize,
          categoryTag: categoryTag,
        );
      } on DioException catch (fallbackError) {
        throw OffException(
          _formatDioMessage(fallbackError, 'Unable to search OFF.'),
        );
      }
    } catch (_) {
      throw OffException('Unable to search OFF.');
    }
  }

  Future<List<OffProductResponse>> _searchCgi(
    String query, {
    required int pageSize,
    String? categoryTag,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/cgi/search.pl',
      queryParameters: _buildSearchParams(
        query,
        pageSize: pageSize,
        categoryTag: categoryTag,
        includeCgiParams: true,
      ),
    );
    return _parseSearchResponse(response.data);
  }

  Future<List<OffProductResponse>> _searchV2(
    String query, {
    required int pageSize,
    String? categoryTag,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/v2/search',
      queryParameters: _buildSearchParams(
        query,
        pageSize: pageSize,
        categoryTag: categoryTag,
        includeCgiParams: false,
      ),
    );
    return _parseSearchResponse(response.data);
  }

  Map<String, dynamic> _buildSearchParams(
    String query, {
    required int pageSize,
    String? categoryTag,
    required bool includeCgiParams,
  }) {
    final params = <String, dynamic>{
      'search_terms': query,
      'lc': 'en',
      'user_agent': _userAgent,
      'fields': _fields.join(','),
      'page_size': pageSize,
    };
    if (includeCgiParams) {
      params['search_simple'] = 1;
      params['action'] = 'process';
      params['json'] = 1;
    }
    int tagIndex = 0;
    void addTagFilter(String type, String tag) {
      params['tagtype_$tagIndex'] = type;
      params['tag_contains_$tagIndex'] = 'contains';
      params['tag_$tagIndex'] = tag;
      tagIndex++;
    }

    if (_countryTag.isNotEmpty) {
      addTagFilter('countries', _countryTag);
    }
    if (categoryTag != null && categoryTag.trim().isNotEmpty) {
      addTagFilter('categories', categoryTag.trim());
    }
    return params;
  }

  List<OffProductResponse> _parseSearchResponse(Map<String, dynamic>? data) {
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
  }

  String _formatDioMessage(DioException error, String fallback) {
    final statusCode = error.response?.statusCode;
    if (statusCode == null) {
      return fallback;
    }
    return '$fallback (HTTP $statusCode)';
  }
}
