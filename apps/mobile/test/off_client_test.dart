import 'package:dio/dio.dart';
import 'package:fitness_app/features/nutrition/data/off_client.dart';
import 'package:fitness_app/features/nutrition/data/off_rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestRateLimiter extends OffRateLimiter {
  int callCount = 0;

  @override
  Future<T> run<T>(String key, Future<T> Function() action) {
    callCount += 1;
    if (callCount == 1) {
      return action();
    }
    throw StateError('Rate limiter failure');
  }
}

void main() {
  test('searchProducts wraps DioException in OffException with status code '
      'when both primary and fallback hosts fail', () async {
    final dio = Dio();
    final requestedHosts = <String>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestedHosts.add(options.uri.host);
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(requestOptions: options, statusCode: 500),
            ),
          );
        },
      ),
    );

    final rateLimiter = _TestRateLimiter();
    final client = OffClient(dio: dio, rateLimiter: rateLimiter);

    await expectLater(
      () async => await client.searchProducts('apple'),
      throwsA(
        isA<OffException>().having(
          (error) => error.message,
          'message',
          contains('Unable to search OFF.'),
        ),
      ),
    );

    // One rate-limiter slot covers the primary attempt plus its fallback
    // retry, so the OFF call budget isn't double-spent on a single search.
    expect(rateLimiter.callCount, 1);
    expect(requestedHosts, [
      'search.openfoodfacts.org',
      'search.openfoodfacts.net',
    ]);
  });

  test('searchProducts falls back to staging search-a-licious on a primary '
      '5xx, dropping lc and tag filters the fallback host rejects, and '
      'returns its parsed hits', () async {
    final dio = Dio();
    final fallbackParams = <String, dynamic>{};
    Map<String, dynamic>? primaryParams;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.host == 'search.openfoodfacts.org') {
            primaryParams = options.queryParameters;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: options, statusCode: 503),
              ),
            );
            return;
          }
          fallbackParams.addAll(options.queryParameters);
          expect(options.headers['Authorization'], 'Basic b2ZmOm9mZg==');
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'hits': [
                  {'code': '123', 'product_name': 'Fallback Apple'},
                ],
              },
            ),
          );
        },
      ),
    );

    final client = OffClient(
      dio: dio,
      rateLimiter: OffRateLimiter(),
      country: 'uk',
    );
    final results = await client.searchProducts('apple');

    expect(results, hasLength(1));
    expect(results.single.product['product_name'], 'Fallback Apple');

    // Primary keeps the country tag filter; the fallback host's index
    // config doesn't expose countries_tags as a search field (400
    // QueryCheckError), so it gets a plain query with no `lc` param either.
    expect(primaryParams!['q'], contains('countries_tags'));
    expect(fallbackParams['q'], 'apple');
    expect(fallbackParams.containsKey('lc'), isFalse);
  });

  test('searchProducts falls back on a primary 422 (unrecognized-param '
      'rejection, e.g. after a prod search-a-licious upgrade)', () async {
    final dio = Dio();
    final requestedHosts = <String>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestedHosts.add(options.uri.host);
          if (options.uri.host == 'search.openfoodfacts.org') {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: options, statusCode: 422),
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'hits': <Map<String, dynamic>>[]},
            ),
          );
        },
      ),
    );

    final client = OffClient(dio: dio, rateLimiter: OffRateLimiter());
    await client.searchProducts('apple');

    expect(requestedHosts, [
      'search.openfoodfacts.org',
      'search.openfoodfacts.net',
    ]);
  });

  test('searchProducts falls back on a primary 400 for that search, but a 400 '
      'does not start the cooldown — the next search still tries primary '
      'first (so a persistent query bug keeps logging instead of being '
      'masked once per cooldown window)', () async {
    final dio = Dio();
    final requestedHosts = <String>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestedHosts.add(options.uri.host);
          if (options.uri.host == 'search.openfoodfacts.org') {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: options, statusCode: 400),
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'hits': <Map<String, dynamic>>[]},
            ),
          );
        },
      ),
    );

    final client = OffClient(dio: dio, rateLimiter: OffRateLimiter());

    await client.searchProducts('apple');
    await client.searchProducts('banana');

    expect(requestedHosts, [
      'search.openfoodfacts.org',
      'search.openfoodfacts.net',
      'search.openfoodfacts.org',
      'search.openfoodfacts.net',
    ]);
  });

  test(
    'searchProducts does not fall back on a non-retryable 4xx from primary',
    () async {
      final dio = Dio();
      final requestedHosts = <String>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestedHosts.add(options.uri.host);
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: options, statusCode: 404),
              ),
            );
          },
        ),
      );

      final client = OffClient(dio: dio, rateLimiter: OffRateLimiter());

      await expectLater(
        () async => await client.searchProducts('apple'),
        throwsA(isA<OffException>()),
      );

      expect(requestedHosts, ['search.openfoodfacts.org']);
    },
  );

  test('searchProducts enters a cooldown after a primary failure and skips '
      'straight to fallback until it expires', () async {
    final dio = Dio();
    final requestedHosts = <String>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestedHosts.add(options.uri.host);
          if (options.uri.host == 'search.openfoodfacts.org') {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: options, statusCode: 502),
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'hits': <Map<String, dynamic>>[]},
            ),
          );
        },
      ),
    );

    var now = DateTime(2026, 7, 15, 12);
    final client = OffClient(
      dio: dio,
      rateLimiter: OffRateLimiter(),
      now: () => now,
    );

    await client.searchProducts('apple');
    expect(requestedHosts, [
      'search.openfoodfacts.org',
      'search.openfoodfacts.net',
    ]);

    requestedHosts.clear();
    now = now.add(const Duration(minutes: 1));
    await client.searchProducts('banana');
    expect(requestedHosts, ['search.openfoodfacts.net']);

    requestedHosts.clear();
    now = now.add(const Duration(minutes: 5));
    await client.searchProducts('cherry');
    expect(requestedHosts, [
      'search.openfoodfacts.org',
      'search.openfoodfacts.net',
    ]);
  });

  test('fetchProduct returns null on HTTP 404 (code unknown to OFF, e.g. a '
      'scanned QR that is not a food barcode)', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(requestOptions: options, statusCode: 404),
            ),
          );
        },
      ),
    );

    final client = OffClient(dio: dio, rateLimiter: OffRateLimiter());

    expect(await client.fetchProduct('B08DH161T6'), isNull);
  });

  test('fetchProduct wraps non-404 DioExceptions in OffException with the '
      'friendly formatted message, never Dio\'s raw exception text', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException.badResponse(
              statusCode: 500,
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 500),
            ),
          );
        },
      ),
    );

    final client = OffClient(dio: dio, rateLimiter: OffRateLimiter());

    await expectLater(
      () async => await client.fetchProduct('5000159484695'),
      throwsA(
        isA<OffException>().having(
          (error) => error.message,
          'message',
          'Unable to fetch from OFF. (HTTP 500)',
        ),
      ),
    );
  });

  test('searchProducts rethrows a cancel DioException (isCancel) instead of '
      'wrapping it into OffException', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          // Keep the request pending until the token is cancelled, then mirror
          // Dio's own cancel propagation by rejecting with the cancel error.
          options.cancelToken?.whenCancel.then((err) => handler.reject(err));
        },
      ),
    );

    // Fresh limiter (never OffRateLimiter.shared) so timestamps don't leak.
    final client = OffClient(dio: dio, rateLimiter: OffRateLimiter());
    final token = CancelToken();
    final future = client.searchProducts('apple', cancelToken: token);
    token.cancel('superseded');

    await expectLater(
      future,
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
