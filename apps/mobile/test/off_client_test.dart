import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/data/off_client.dart';
import 'package:fitness_app/features/nutrition/data/off_rate_limiter.dart';

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
  test('searchProducts wraps DioException in OffException with status code',
      () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions: options,
                statusCode: 500,
              ),
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

    expect(rateLimiter.callCount, 1);
  });

  test(
      'searchProducts rethrows a cancel DioException (isCancel) instead of '
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
