import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/app_log.dart';
import '../../../core/environment.dart';
import 'off_rate_limiter.dart';

class OffException implements Exception {
  OffException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OffProductResponse {
  OffProductResponse({required this.product, required this.rawJson});

  final Map<String, dynamic> product;
  final String rawJson;
}

class OffClient {
  OffClient({
    Dio? dio,
    String? userAgent,
    String? country,
    OffRateLimiter? rateLimiter,
  }) : _countryTag = _normalizeCountryTag(
         country ?? EnvironmentConfig.offCountry,
       ),
       _rateLimiter = rateLimiter ?? OffRateLimiter.shared,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: _baseUrl,
               // Dio defaults to NO timeouts. During OFF outages the server
               // sometimes hangs instead of fast-failing; without these the
               // in-flight future never resolves and the live-search loading
               // line stays on forever (same values as auth_service /
               // off_image_downloader).
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 20),
               headers: {
                 'User-Agent': userAgent ?? EnvironmentConfig.offUserAgent,
               },
             ),
           );

  static const String _baseUrl = 'https://world.openfoodfacts.org';
  // Text search uses the Search-a-licious backend instead of the legacy
  // /api/v2/search endpoint, which is chronically overloaded and returns 503s.
  static const String _searchUrl = 'https://search.openfoodfacts.org/search';
  static const List<String> _fields = [
    'code',
    'product_name',
    'product_name_en',
    'generic_name',
    'brands',
    'serving_size',
    'serving_quantity',
    'serving_quantity_unit',
    'completeness',
    'nutriments',
    // Needed by cooked-basis detection (see detectCookedNutritionBasis).
    // Search-a-licious ignores the nested selector; barcode fetches return
    // just the ~1 KB agribalyse block rather than the full ecoscore payload.
    'categories_tags',
    'ecoscore_data.agribalyse',
    'lang',
    'images',
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
  final OffRateLimiter _rateLimiter;

  Future<OffProductResponse?> fetchProduct(String barcode) async {
    final trimmedBarcode = barcode.trim();
    try {
      final response = await _rateLimiter.run(
        _barcodeKey(trimmedBarcode),
        () => _dio.get<Map<String, dynamic>>(
          '/api/v2/product/$trimmedBarcode',
          queryParameters: {'fields': _fields.join(',')},
        ),
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
        return OffProductResponse(product: product, rawJson: jsonEncode(data));
      }
      return null;
    } on OffRateLimitException {
      rethrow;
    } on DioException catch (error) {
      // OFF answers an unknown or malformed code (e.g. a scanned QR that
      // decodes to an Amazon ASIN) with HTTP 404 — that is "no such product",
      // not a failure, and must map to the page's friendly not-found banner.
      if (error.response?.statusCode == 404) {
        return null;
      }
      // Never surface Dio's raw exception text (error.message) to the UI.
      throw OffException(_formatDioMessage(error, 'Unable to fetch from OFF.'));
    } catch (error, stackTrace) {
      logError('off.fetchProduct', error, stackTrace);
      throw OffException('Unable to fetch from OFF.');
    }
  }

  Future<List<OffProductResponse>> searchProducts(
    String query, {
    int pageSize = 10,
    String? categoryTag,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _rateLimiter.run(
        _searchKey(query),
        () => _dio.get<Map<String, dynamic>>(
          _searchUrl,
          queryParameters: _buildSearchParams(
            query,
            pageSize: pageSize,
            categoryTag: categoryTag,
          ),
          // Forwarded so a superseded live search aborts the socket and frees
          // rate-limit budget instead of completing and being discarded.
          cancelToken: cancelToken,
        ),
      );
      return _parseSearchResponse(response.data);
    } on OffRateLimitException {
      rethrow;
    } on DioException catch (error) {
      // A cancelled request must stay a cancel — never convert it into a
      // user-facing OffException, or the live path would surface an error
      // string for routine supersede-cancellation (RESEARCH Pitfall 4).
      if (CancelToken.isCancel(error)) rethrow;
      throw OffException(_formatDioMessage(error, 'Unable to search OFF.'));
    } catch (error, stackTrace) {
      logError('off.searchProducts', error, stackTrace);
      throw OffException('Unable to search OFF.');
    }
  }

  Map<String, dynamic> _buildSearchParams(
    String query, {
    required int pageSize,
    String? categoryTag,
  }) {
    // Search-a-licious uses a Lucene-style query string. Tag filters are
    // appended to `q` as `field:"value"` clauses; the value must be quoted
    // because the tag values themselves contain a colon (e.g. en:beverages).
    final clauses = <String>[];
    final trimmedQuery = query.trim();
    if (trimmedQuery.isNotEmpty) {
      clauses.add(trimmedQuery);
    }
    if (_countryTag.isNotEmpty) {
      clauses.add('countries_tags:"$_countryTag"');
    }
    final trimmedCategory = categoryTag?.trim();
    if (trimmedCategory != null && trimmedCategory.isNotEmpty) {
      clauses.add('categories_tags:"$trimmedCategory"');
    }
    return <String, dynamic>{
      'q': clauses.join(' '),
      'lc': 'en',
      'fields': _fields.join(','),
      'page_size': pageSize,
    };
  }

  List<OffProductResponse> _parseSearchResponse(Map<String, dynamic>? data) {
    if (data == null) {
      return [];
    }
    final products = data['hits'];
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

  String _barcodeKey(String barcode) => 'barcode:${barcode.trim()}';

  String _searchKey(String query) => 'search:${query.trim().toLowerCase()}';
}
