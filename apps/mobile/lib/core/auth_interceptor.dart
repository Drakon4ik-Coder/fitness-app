import 'package:dio/dio.dart';

import 'auth_service.dart';
import 'auth_storage.dart';
import 'environment.dart';

class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required AuthStorage storage,
    required AuthService authService,
    required Future<void> Function() onSessionExpired,
    required String accessToken,
  })  : _storage = storage,
        _authService = authService,
        _onSessionExpired = onSessionExpired,
        _accessToken = accessToken,
        _retryClient = Dio(
          BaseOptions(baseUrl: EnvironmentConfig.apiBaseUrl),
        );

  final AuthStorage _storage;
  final AuthService _authService;
  final Future<void> Function() _onSessionExpired;
  final Dio _retryClient;
  final List<Dio> _dios = [];

  String _accessToken;
  Future<String?>? _refreshing;

  void attachTo(Dio dio) {
    dio.options.headers['Authorization'] = 'Bearer $_accessToken';
    dio.interceptors.add(this);
    _dios.add(dio);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final is401 = err.response?.statusCode == 401;
    final alreadyRetried = err.requestOptions.extra['retried'] == true;
    final isRefreshCall =
        err.requestOptions.path.contains('/auth/refresh');

    if (!is401 || alreadyRetried || isRefreshCall) {
      return handler.next(err);
    }

    final newToken = await _ensureRefreshed();
    if (newToken == null) {
      await _onSessionExpired();
      return handler.next(err);
    }

    final opts = err.requestOptions;
    opts.headers['Authorization'] = 'Bearer $newToken';
    opts.extra['retried'] = true;
    try {
      final response = await _retryClient.fetch(opts);
      return handler.resolve(response);
    } on DioException catch (e) {
      return handler.next(e);
    }
  }

  Future<String?> _ensureRefreshed() {
    return _refreshing ??=
        _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<String?> _doRefresh() async {
    final refreshToken = await _storage.getRefreshToken();
    if (refreshToken == null) return null;
    try {
      final access = await _authService.refresh(refreshToken);
      await _storage.saveAccessToken(access);
      _accessToken = access;
      for (final d in _dios) {
        d.options.headers['Authorization'] = 'Bearer $access';
      }
      return access;
    } on AuthException {
      return null;
    }
  }
}
