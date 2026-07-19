import 'package:dio/dio.dart';

import '../../../core/auth_interceptor.dart';
import '../../../core/environment.dart';
import 'api_exceptions.dart';
import 'fatsecret_mapper.dart' show asFatSecretMapList;
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
               // Dio defaults to NO timeouts. This client drives loading UI
               // (live-search progress line, enrich-on-tap spinner); a stalled
               // connection would pin those on forever. Same standard values
               // as off_client / auth_service / off_image_downloader; the
               // proxy's own upstream budget (5s connect + 15s read) fits
               // inside them, so a slow-but-alive proxy still answers first.
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 20),
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

  /// GET .../fatsecret/search. Accepts both free-tier v1 (`foods.food`) and
  /// image-capable v3 (`foods_search.results.food`) passthrough bodies, then
  /// normalizes FatSecret's object-vs-array-vs-absent quirk so callers always
  /// see a plain list.
  ///
  /// The rate-limiter wraps the whole mapped call so a budget-exhausted
  /// [OffRateLimitException] reaches the caller untouched — [mapApiErrors]
  /// only ever sees (and classifies) genuine transport/HTTP failures.
  Future<List<Map<String, dynamic>>> searchFoods(
    String query, {
    int maxResults = 10,
    CancelToken? cancelToken,
  }) {
    // The cancel token's identity is part of the request identity: a deduped
    // future stays governed by the ORIGINAL caller's token, so handing it to
    // a caller with a different token would let the first caller's
    // supersede-cancel kill the second caller's search — it completes as a
    // cancel, which live search drops silently and never reissues.
    final tokenId = cancelToken == null ? '' : identityHashCode(cancelToken);
    return _rateLimiter.run(
      // maxResults is part of the request identity: in-flight dedup hands the
      // same future to concurrent callers, and a caller asking for a different
      // limit must not silently receive another caller's result count.
      'fs-search:$maxResults:$tokenId:${query.trim().toLowerCase()}',
      () => mapApiErrors('Unable to search FatSecret.', () async {
        final response = await _dio.get<Map<String, dynamic>>(
          '/api/v1/foods/fatsecret/search',
          queryParameters: {'q': query, 'max_results': maxResults},
          cancelToken: cancelToken,
        );
        final body = response.data;
        final v3 = body?['foods_search'];
        if (v3 is Map) {
          final results = v3['results'];
          if (results is Map) return asFatSecretMapList(results['food']);
          return const <Map<String, dynamic>>[];
        }
        final v1 = body?['foods'];
        if (v1 is Map) return asFatSecretMapList(v1['food']);
        return const <Map<String, dynamic>>[];
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
}
