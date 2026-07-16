import 'package:dio/dio.dart';
import 'package:fitness_app/features/nutrition/data/api_exceptions.dart';
import 'package:fitness_app/features/nutrition/data/fatsecret_client.dart';
import 'package:fitness_app/features/nutrition/data/off_rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FatSecretClient.sharedLimiter is never OffRateLimiter.shared — the '
      'two partners must not spend each other\'s call budget', () {
    expect(
      identical(FatSecretClient.sharedLimiter, OffRateLimiter.shared),
      isFalse,
    );
  });

  test('a throttled FatSecretClient limiter names FatSecret, not '
      'OpenFoodFacts, in the exception message', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'foods': {'total_results': '0'},
              },
            ),
          );
        },
      ),
    );
    // maxCalls: 1 so the first call spends the sole slot and the second one
    // throttles deterministically.
    final limiter = OffRateLimiter(maxCalls: 1, serviceName: 'FatSecret');
    final client = FatSecretClient(
      accessToken: 'test-token',
      dio: dio,
      rateLimiter: limiter,
    );

    await client.searchFoods('burger');

    await expectLater(
      () async => await client.searchFoods('burger'),
      throwsA(
        isA<OffRateLimitException>().having(
          (error) => error.message,
          'message',
          contains('FatSecret is temporarily rate limited'),
        ),
      ),
    );
  });

  test('concurrent same-query searches with different maxResults are not '
      'deduped into one request — each caller gets its own limit', () async {
    final dio = Dio();
    final requestedLimits = <String>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final limit = options.queryParameters['max_results'].toString();
          requestedLimits.add(limit);
          // Echo the limit back as the sole hit's id so each caller's
          // payload is attributable to its own request.
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'foods': {
                  'food': {'food_id': limit, 'food_name': 'Echo'},
                },
              },
            ),
          );
        },
      ),
    );
    final client = FatSecretClient(
      accessToken: 'test-token',
      dio: dio,
      rateLimiter: OffRateLimiter(),
    );

    final results = await Future.wait([
      client.searchFoods('burger', maxResults: 5),
      client.searchFoods('burger', maxResults: 25),
    ]);

    expect(requestedLimits, unorderedEquals(['5', '25']));
    expect(results[0].single['food_id'], '5');
    expect(results[1].single['food_id'], '25');
  });

  test('concurrent same-query searches with different cancel tokens are not '
      'deduped — a superseded caller\'s cancel must not kill the fresh '
      'search', () async {
    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests += 1;
          if (requests == 1) {
            // The first caller is superseded mid-flight: complete its request
            // as a cancel, exactly as a live-search keystroke would.
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.cancel,
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'foods': {
                  'food': {'food_id': '7', 'food_name': 'Fresh'},
                },
              },
            ),
          );
        },
      ),
    );
    final client = FatSecretClient(
      accessToken: 'test-token',
      dio: dio,
      rateLimiter: OffRateLimiter(),
    );

    // Both calls start in the same synchronous stretch, so the first request
    // is still in the limiter's in-flight map when the second one asks — the
    // exact window where a query-only dedup key hands back the doomed future.
    final doomed = client
        .searchFoods('burger', cancelToken: CancelToken())
        .then<Object>((hits) => hits, onError: (Object error) => error);
    final fresh = client.searchFoods('burger', cancelToken: CancelToken());

    expect(await doomed, isA<DioException>());
    expect((await fresh).single['food_id'], '7');
    expect(requests, 2);
  });

  test('concurrent same-query searches with the same cancel token still '
      'dedup into one request', () async {
    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests += 1;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'foods': {
                  'food': {'food_id': '1', 'food_name': 'Shared'},
                },
              },
            ),
          );
        },
      ),
    );
    final client = FatSecretClient(
      accessToken: 'test-token',
      dio: dio,
      rateLimiter: OffRateLimiter(),
    );

    final token = CancelToken();
    final results = await Future.wait([
      client.searchFoods('burger', cancelToken: token),
      client.searchFoods('burger', cancelToken: token),
    ]);

    expect(requests, 1);
    expect(results[0].single['food_id'], '1');
    expect(results[1].single['food_id'], '1');
  });

  test(
    'searchFoods sends q/max_results and normalizes a multi-hit list',
    () async {
      final dio = Dio();
      Map<String, dynamic>? sentParams;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            sentParams = options.queryParameters;
            expect(options.path, '/api/v1/foods/fatsecret/search');
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'foods': {
                    'food': [
                      {'food_id': '1', 'food_name': 'A'},
                      {'food_id': '2', 'food_name': 'B'},
                    ],
                    'max_results': '10',
                    'page_number': '0',
                    'total_results': '2',
                  },
                },
              ),
            );
          },
        ),
      );

      final client = FatSecretClient(
        accessToken: 'test-token',
        dio: dio,
        rateLimiter: OffRateLimiter(),
      );
      final results = await client.searchFoods('burger', maxResults: 10);

      expect(sentParams!['q'], 'burger');
      expect(sentParams!['max_results'], 10);
      expect(results, hasLength(2));
      expect(results[0]['food_id'], '1');
      expect(results[1]['food_id'], '2');
    },
  );

  test('searchFoods normalizes a single-hit object (not a list) into a '
      'one-element list', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'foods': {
                  'food': {'food_id': '1', 'food_name': 'Solo'},
                  'total_results': '1',
                },
              },
            ),
          );
        },
      ),
    );

    final client = FatSecretClient(
      accessToken: 'test-token',
      dio: dio,
      rateLimiter: OffRateLimiter(),
    );
    final results = await client.searchFoods('solo');

    expect(results, hasLength(1));
    expect(results.single['food_id'], '1');
  });

  test('searchFoods returns an empty list when foods.food is absent (zero '
      'hits)', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'foods': {'total_results': '0'},
              },
            ),
          );
        },
      ),
    );

    final client = FatSecretClient(
      accessToken: 'test-token',
      dio: dio,
      rateLimiter: OffRateLimiter(),
    );
    final results = await client.searchFoods('nonexistent');

    expect(results, isEmpty);
  });

  test('getFood returns the food map, null when absent', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.path, '/api/v1/foods/fatsecret/food/33691');
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'food': {'food_id': '33691', 'food_name': 'Big Mac'},
              },
            ),
          );
        },
      ),
    );

    final client = FatSecretClient(
      accessToken: 'test-token',
      dio: dio,
      rateLimiter: OffRateLimiter(),
    );
    final food = await client.getFood('33691');

    expect(food, isNotNull);
    expect(food!['food_id'], '33691');
  });

  test('getFood returns null when the body carries no food key', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{},
            ),
          );
        },
      ),
    );

    final client = FatSecretClient(
      accessToken: 'test-token',
      dio: dio,
      rateLimiter: OffRateLimiter(),
    );
    expect(await client.getFood('1'), isNull);
  });

  test('a 503 (partner not configured) maps to a server-verdict ApiException '
      '(isNetworkError false) — never queued for offline replay', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(requestOptions: options, statusCode: 503),
            ),
          );
        },
      ),
    );

    final client = FatSecretClient(
      accessToken: 'test-token',
      dio: dio,
      rateLimiter: OffRateLimiter(),
    );

    await expectLater(
      () async => await client.searchFoods('burger'),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'statusCode', 503)
            .having((error) => error.isNetworkError, 'isNetworkError', isFalse),
      ),
    );
  });

  test('a connection error (no HTTP response) maps to isNetworkError true — '
      'the offline-replay class of failure', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            ),
          );
        },
      ),
    );

    final client = FatSecretClient(
      accessToken: 'test-token',
      dio: dio,
      rateLimiter: OffRateLimiter(),
    );

    await expectLater(
      () async => await client.searchFoods('burger'),
      throwsA(
        isA<ApiException>().having(
          (error) => error.isNetworkError,
          'isNetworkError',
          isTrue,
        ),
      ),
    );
  });

  test('a superseded (cancelled) search stays a cancel — recognizable via '
      'CancelToken.isCancel, never a logged ApiException', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
            ),
          );
        },
      ),
    );

    final client = FatSecretClient(
      accessToken: 'test-token',
      dio: dio,
      rateLimiter: OffRateLimiter(),
    );

    await expectLater(
      () async => await client.searchFoods('burger'),
      throwsA(
        isA<DioException>().having(
          (error) => CancelToken.isCancel(error),
          'isCancel',
          isTrue,
        ),
      ),
    );
  });
}
