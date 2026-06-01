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
  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _sendTimeout = Duration(seconds: 10);
  static const Duration _receiveTimeout = Duration(seconds: 20);

  AuthService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: EnvironmentConfig.apiBaseUrl,
                connectTimeout: _connectTimeout,
                sendTimeout: _sendTimeout,
                receiveTimeout: _receiveTimeout,
              ),
            );

  final Dio _dio;

  Future<AuthTokens> login({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _dio.post(
        '/api/v1/auth/token',
        data: {
          'email': email,
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
        // Surfaces server messages such as the email-verification gate,
        // falling back to a generic credential error.
        final message = _firstErrorMessage(error.response?.data);
        throw AuthException(message ?? 'Invalid email or password.');
      }
      throw AuthException('Unable to sign in. Please try again.');
    } catch (_) {
      throw AuthException('Unable to sign in. Please try again.');
    }
  }

  Future<String> refresh(String refreshToken) async {
    try {
      final response = await _dio.post(
        '/api/v1/auth/refresh',
        data: {'refresh': refreshToken},
      );
      final data = response.data;
      if (data is Map && data['access'] is String) {
        return data['access'] as String;
      }
      throw AuthException('Unexpected response from server.');
    } on DioException {
      throw AuthException('Session expired. Please sign in again.');
    }
  }

  Future<void> register({
    required String email,
    required String password,
  }) async {
    try {
      await _dio.post(
        '/api/v1/auth/register',
        data: {
          'email': email,
          'password': password,
        },
      );
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 400) {
        final message = _firstErrorMessage(error.response?.data);
        throw AuthException(message ?? 'Please check your details and try again.');
      }
      throw AuthException('Unable to register. Please try again later.');
    } catch (_) {
      throw AuthException('Unable to register. Please try again later.');
    }
  }

  /// Extracts the first field error message from a DRF validation response.
  ///
  /// DRF returns errors as `{ "field": ["message", ...], ... }`. We surface the
  /// first message of the first field so the user sees one specific reason.
  String? _firstErrorMessage(dynamic data) {
    if (data is Map) {
      for (final value in data.values) {
        if (value is List && value.isNotEmpty) {
          return value.first.toString();
        }
        if (value is String && value.isNotEmpty) {
          return value;
        }
      }
    }
    if (data is List && data.isNotEmpty) {
      return data.first.toString();
    }
    return null;
  }
}
