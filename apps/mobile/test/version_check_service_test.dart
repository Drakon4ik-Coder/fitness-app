import 'package:dio/dio.dart';
import 'package:fitness_app/core/version_check_service.dart';
import 'package:flutter_test/flutter_test.dart';

Dio _dioReturning(Object? data, {int statusCode = 200}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response(requestOptions: options, statusCode: statusCode, data: data),
        );
      },
    ),
  );
  return dio;
}

void main() {
  test('fetchMinSupportedBuild reads the /health/ field', () async {
    final service = VersionCheckService(
      dio: _dioReturning({
        'status': 'ok',
        'version': '1.0.0',
        'min_supported_build': 417,
      }),
    );

    expect(await service.fetchMinSupportedBuild(), 417);
  });

  test('a backend without the field means no minimum, not an error', () async {
    final service = VersionCheckService(
      dio: _dioReturning({'status': 'ok', 'version': '1.0.0'}),
    );

    expect(await service.fetchMinSupportedBuild(), 0);
  });

  test('a non-integer value throws instead of blocking', () async {
    final service = VersionCheckService(
      dio: _dioReturning({'min_supported_build': 'soon'}),
    );

    expect(
      () => service.fetchMinSupportedBuild(),
      throwsA(isA<FormatException>()),
    );
  });
}
