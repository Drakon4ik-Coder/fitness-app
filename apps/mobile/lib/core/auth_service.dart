import 'package:dio/dio.dart';

import 'environment.dart';

class AuthTokens {
  const AuthTokens({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}

class AuthException implements Exception {
  AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AuthService {
  AuthService({Dio? dio})
      : _dio = dio ?? Dio(BaseOptions(baseUrl: EnvironmentConfig.apiBaseUrl));

  final Dio _dio;

  Future<AuthTokens> login({
    required String username,
    required String password,
  }) async {
    try {
      final response = await _dio.post(
        '/api/v1/auth/token',
        data: {
          'username': username,
          'password': password,
        },
      );
      final data = response.data;
      if (data is Map) {
        final access = data['access'] as String?;
        final refresh = data['refresh'] as String?;
        if (access != null && refresh != null) {
          return AuthTokens(accessToken: access, refreshToken: refresh);
        }
      }
      throw AuthException('Unexpected response from server.');
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 401 || statusCode == 400) {
        throw AuthException('Invalid username or password.');
      }
      throw AuthException('Unable to sign in. Please try again.');
    } catch (_) {
      throw AuthException('Unable to sign in. Please try again.');
    }
  }

  Future<void> register({
    required String username,
    required String password,
    String? email,
  }) async {
    final trimmedEmail = email?.trim() ?? '';
    try {
      await _dio.post(
        '/api/v1/auth/register',
        data: {
          'username': username,
          'password': password,
          if (trimmedEmail.isNotEmpty) 'email': trimmedEmail,
        },
      );
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 400) {
        throw AuthException('Please check your details and try again.');
      }
      throw AuthException('Unable to register. Please try again.');
    } catch (_) {
      throw AuthException('Unable to register. Please try again.');
    }
  }
}
