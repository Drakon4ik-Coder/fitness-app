import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_interceptor.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/core/auth_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Resolves every request with a minimal /auth/me payload while recording the
/// Authorization header each request actually carried.
Dio _captureDio(List<String?> sentAuthHeaders) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        sentAuthHeaders.add(options.headers['Authorization'] as String?);
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: {'email': 'me@example.com', 'display_name': 'Casey'},
          ),
        );
      },
    ),
  );
  return dio;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('with an interceptor attached, authenticated calls use the '
      'interceptor-owned header, not the caller-supplied token', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final sentAuthHeaders = <String?>[];
    final dio = _captureDio(sentAuthHeaders);

    // The interceptor holds a newer token than the one AuthGate captured at
    // launch — the state after any transparent refresh. The stale token the
    // widget tree still passes must not override the refreshed base header.
    final interceptor = AuthInterceptor(
      storage: AuthStorage(),
      authService: AuthService(dio: Dio()),
      onSessionExpired: () async {},
      accessToken: 'fresh-token',
    );
    final service = AuthService(dio: dio, authInterceptor: interceptor);

    final info = await service.fetchMe(accessToken: 'stale-token');

    expect(info?.email, 'me@example.com');
    expect(sentAuthHeaders, ['Bearer fresh-token']);
  });

  test(
    'without an interceptor, authenticated calls send the explicit token',
    () async {
      final sentAuthHeaders = <String?>[];
      final service = AuthService(dio: _captureDio(sentAuthHeaders));

      final info = await service.fetchMe(accessToken: 'my-token');

      expect(info?.email, 'me@example.com');
      expect(sentAuthHeaders, ['Bearer my-token']);
    },
  );
}
