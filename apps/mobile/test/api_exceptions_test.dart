import 'package:dio/dio.dart';
import 'package:fitness_app/core/app_log.dart';
import 'package:fitness_app/features/nutrition/data/api_exceptions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final options = RequestOptions(path: '/x');

  test('passes through the request result', () async {
    final result = await mapApiErrors('friendly', () async => 42);
    expect(result, 42);
  });

  test('no-response DioException maps to a network error', () async {
    // Offline/DNS/timeout failures never got an HTTP response; the outbox
    // replays these (KAN-28), so the classification must hold exactly.
    await expectLater(
      mapApiErrors<void>('friendly', () async {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }),
      throwsA(
        isA<ApiException>()
            .having((e) => e.message, 'message', 'friendly')
            .having((e) => e.isNetworkError, 'isNetworkError', true)
            .having((e) => e.statusCode, 'statusCode', null),
      ),
    );
  });

  test('HTTP-response DioException maps to a server verdict', () async {
    await expectLater(
      mapApiErrors<void>('friendly', () async {
        throw DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 400),
        );
      }),
      throwsA(
        isA<ApiException>()
            .having((e) => e.isNetworkError, 'isNetworkError', false)
            .having((e) => e.statusCode, 'statusCode', 400),
      ),
    );
  });

  test('a cancelled request is rethrown as-is, never wrapped', () async {
    // Live search cancels superseded keystrokes; those must stay
    // CancelToken.isCancel-recognizable for the controller's silent-swallow
    // branch, not become logged ApiException "failures".
    await expectLater(
      mapApiErrors<void>('friendly', () async {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
        );
      }),
      throwsA(
        isA<DioException>().having(
          (e) => CancelToken.isCancel(e),
          'isCancel',
          isTrue,
        ),
      ),
    );
  });

  test(
    'ApiException from inside the request passes through untouched',
    () async {
      final original = ApiException('specific', statusCode: 418);
      await expectLater(
        mapApiErrors<void>('friendly', () async => throw original),
        throwsA(same(original)),
      );
    },
  );

  test('unexpected errors map to a plain ApiException', () async {
    await expectLater(
      mapApiErrors<void>('friendly', () async => throw StateError('boom')),
      throwsA(
        isA<ApiException>()
            .having((e) => e.message, 'message', 'friendly')
            .having((e) => e.isNetworkError, 'isNetworkError', false),
      ),
    );
  });

  test('original error reaches the configured logger', () async {
    Object? logged;
    String? loggedContext;
    appErrorLogger = (context, error, stackTrace) {
      loggedContext = context;
      logged = error;
    };
    addTearDown(() => appErrorLogger = null);

    await expectLater(
      mapApiErrors<void>('friendly', () async => throw StateError('boom')),
      throwsA(isA<ApiException>()),
    );
    expect(loggedContext, 'friendly');
    expect(logged, isA<StateError>());
  });
}
