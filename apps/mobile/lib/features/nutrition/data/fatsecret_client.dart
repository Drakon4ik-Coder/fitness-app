import 'package:dio/dio.dart';

import '../../../core/auth_interceptor.dart';
import '../../../core/environment.dart';
import 'api_exceptions.dart';
import 'off_rate_limiter.dart';

/// Thin client for the backend's FatSecret proxy endpoints
/// (`/api/v1/foods/fatsecret/...`, KAN-67). Mirrors [FoodsApiService]'s shape
/// — same constructor signature, same Bearer-token/AuthInterceptor wiring —
/// since this is just a second backend-auth'd resource, not a new auth
/// boundary; FatSecret's own credentials never leave the backend.
class FatSecretClient {
  FatSecretClient({
    required String accessToken,
    AuthInterceptor? authInterceptor,
    Dio? dio,
    OffRateLimiter? rateLimiter,
  }) : _rateLimiter = rateLimiter ?? sharedLimiter,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: EnvironmentConfig.apiBaseUrl,
               headers: {'Authorization': 'Bearer $accessToken'},
             ),
           ) {
    authInterceptor?.attachTo(_dio);
  }

  /// FatSecret's own call budget, separate from [OffRateLimiter.shared]:
  /// spending OFF's budget on FatSecret traffic (or vice versa) would
  /// throttle one source for the other's calls.
  static final OffRateLimiter sharedLimiter = OffRateLimiter(
    serviceName: 'FatSecret',
  );

  final Dio _dio;
  final OffRateLimiter _rateLimiter;

  /// Exposed so the live-search controller can pre-flight-check the budget
  /// before firing a call, the same way it does for OFF.
  OffRateLimiter get rateLimiter => _rateLimiter;

  void updateToken(String accessToken) {
    _dio.options.headers['Authorization'] = 'Bearer $accessToken';
  }

  /// GET .../fatsecret/search. Normalizes FatSecret's object-vs-array-vs-absent
  /// quirk on `foods.food` here so callers always see a plain list: a single
  /// hit arrives as a bare object (not a one-element list), and zero hits omit
  /// the key entirely.
  ///
  /// The rate-limiter wraps the whole mapped call so a budget-exhausted
  /// [OffRateLimitException] reaches the caller untouched — [mapApiErrors]
  /// only ever sees (and classifies) genuine transport/HTTP failures.
  Future<List<Map<String, dynamic>>> searchFoods(
    String query, {
    int maxResults = 10,
    CancelToken? cancelToken,
  }) {
    return _rateLimiter.run(
      // maxResults is part of the request identity: in-flight dedup hands the
      // same future to concurrent callers, and a caller asking for a different
      // limit must not silently receive another caller's result count.
      'fs-search:$maxResults:${query.trim().toLowerCase()}',
      () => mapApiErrors('Unable to search FatSecret.', () async {
        final response = await _dio.get<Map<String, dynamic>>(
          '/api/v1/foods/fatsecret/search',
          queryParameters: {'q': query, 'max_results': maxResults},
          cancelToken: cancelToken,
        );
        final foods = response.data?['foods'];
        if (foods is! Map) return const <Map<String, dynamic>>[];
        return _asMapList(foods['food']);
      }),
    );
  }

  /// GET .../fatsecret/food/{id}. Null when the body carries no `food` key
  /// (the backend contract always includes one on success, but a caller must
  /// not crash on an unexpected shape).
  Future<Map<String, dynamic>?> getFood(String foodId) {
    return _rateLimiter.run(
      'fs-food:$foodId',
      () => mapApiErrors('Unable to fetch from FatSecret.', () async {
        final response = await _dio.get<Map<String, dynamic>>(
          '/api/v1/foods/fatsecret/food/$foodId',
        );
        final food = response.data?['food'];
        return food is Map<String, dynamic> ? food : null;
      }),
    );
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is List) {
      return value.whereType<Map<String, dynamic>>().toList();
    }
    if (value is Map) return [value.cast<String, dynamic>()];
    return const [];
  }
}
