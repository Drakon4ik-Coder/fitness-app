import 'package:dio/dio.dart';

import 'app_log.dart';
import 'auth_interceptor.dart';
import 'environment.dart';

class AuthTokens {
  const AuthTokens({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}

/// The signed-in user's editable account info, from GET /auth/me.
class AccountInfo {
  const AccountInfo({
    required this.email,
    required this.displayName,
    this.username = '',
    this.hasPassword = true,
  });

  final String email;
  final String displayName;

  /// The unique @handle, or empty when the user hasn't chosen one yet.
  final String username;

  /// False for OAuth-only accounts. Decides the account-deletion re-auth
  /// method: password prompt vs a fresh Google sign-in.
  final bool hasPassword;
}

class AuthException implements Exception {
  AuthException(this.message, {this.emailUnverified = false});

  final String message;

  /// True when sign-in was rejected because the email isn't verified yet, so
  /// the UI can offer to resend the verification link.
  final bool emailUnverified;

  @override
  String toString() => message;
}

class AuthService {
  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _sendTimeout = Duration(seconds: 10);
  static const Duration _receiveTimeout = Duration(seconds: 20);

  /// [authInterceptor], when given, lets authenticated calls (fetchMe,
  /// updateProfile) transparently refresh an expired access token and retry —
  /// without it a stale token 401s silently.
  AuthService({Dio? dio, AuthInterceptor? authInterceptor})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: EnvironmentConfig.apiBaseUrl,
              connectTimeout: _connectTimeout,
              sendTimeout: _sendTimeout,
              receiveTimeout: _receiveTimeout,
            ),
          ) {
    authInterceptor?.attachTo(_dio);
  }

  final Dio _dio;

  Future<AuthTokens> login({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _dio.post(
        '/api/v1/auth/token',
        data: {'email': email, 'password': password},
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
        final unverified =
            statusCode == 400 &&
            (message?.toLowerCase().contains('confirm your email') ?? false);
        throw AuthException(
          message ?? 'Invalid email or password.',
          emailUnverified: unverified,
        );
      }
      throw AuthException('Unable to sign in. Please try again later.');
    } catch (error, stackTrace) {
      logError('login', error, stackTrace);
      throw AuthException('Unable to sign in. Please try again later.');
    }
  }

  /// Asks the backend to email a fresh verification link. The endpoint always
  /// succeeds (it won't reveal whether the account exists), so this only throws
  /// on a network/server failure.
  Future<void> resendVerification(String email) async {
    try {
      await _dio.post(
        '/api/v1/auth/resend-verification',
        data: {'email': email},
      );
    } on DioException {
      throw AuthException(
        'Could not resend the email. Please try again later.',
      );
    } catch (error, stackTrace) {
      logError('resendVerification', error, stackTrace);
      throw AuthException(
        'Could not resend the email. Please try again later.',
      );
    }
  }

  /// Asks the backend to email a password-reset link. Like
  /// [resendVerification], the endpoint is intentionally silent about whether
  /// the account exists (to avoid account enumeration), so this only throws on
  /// a network/server failure.
  Future<void> requestPasswordReset(String email) async {
    try {
      await _dio.post('/api/v1/auth/password-reset', data: {'email': email});
    } on DioException {
      throw AuthException('Could not send the email. Please try again later.');
    } catch (error, stackTrace) {
      logError('requestPasswordReset', error, stackTrace);
      throw AuthException('Could not send the email. Please try again later.');
    }
  }

  Future<AuthTokens> googleLogin(String idToken) async {
    try {
      final response = await _dio.post(
        '/api/v1/auth/google',
        data: {'id_token': idToken},
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
      if (error.response?.statusCode == 401) {
        final message = _firstErrorMessage(error.response?.data);
        throw AuthException(message ?? 'Google sign-in was rejected.');
      }
      throw AuthException(
        'Unable to sign in with Google. Please try again later.',
      );
    } catch (error, stackTrace) {
      logError('googleLogin', error, stackTrace);
      throw AuthException(
        'Unable to sign in with Google. Please try again later.',
      );
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
    } catch (error, stackTrace) {
      logError('refresh', error, stackTrace);
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
        data: {'email': email, 'password': password},
      );
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 400) {
        final message = _firstErrorMessage(error.response?.data);
        throw AuthException(
          message ?? 'Please check your details and try again.',
        );
      }
      throw AuthException('Unable to register. Please try again later.');
    } catch (error, stackTrace) {
      logError('register', error, stackTrace);
      throw AuthException('Unable to register. Please try again later.');
    }
  }

  /// Reports the device's IANA timezone to the backend (PATCH /auth/me).
  ///
  /// Best-effort: the server defaults users to UTC, and a failed report just
  /// means meal day-grouping/stats stay on the last known zone until next launch.
  Future<void> updateTimezone({
    required String accessToken,
    required String timezone,
  }) async {
    try {
      await _dio.patch(
        '/api/v1/auth/me',
        data: {'timezone': timezone},
        options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      );
    } on DioException {
      // Ignore — non-critical and retried on the next launch.
    }
  }

  /// The signed-in user's account info (GET /auth/me). Returns null on any
  /// failure so the account page can degrade gracefully rather than block.
  Future<AccountInfo?> fetchMe({required String accessToken}) async {
    try {
      final response = await _dio.get(
        '/api/v1/auth/me',
        options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      );
      final data = response.data;
      if (data is Map) {
        return AccountInfo(
          email: (data['email'] as String?) ?? '',
          displayName: (data['display_name'] as String?) ?? '',
          username: (data['username'] as String?) ?? '',
          hasPassword: (data['has_password'] as bool?) ?? true,
        );
      }
      return null;
    } on DioException {
      return null;
    }
  }

  /// Updates profile fields (PATCH /auth/me). Only the provided fields are
  /// sent; [clearUsername] sends an explicit null to release the @handle.
  /// Throws [AuthException] with the server's message on a validation failure.
  Future<void> updateProfile({
    required String accessToken,
    String? displayName,
    String? username,
    bool clearUsername = false,
  }) async {
    try {
      await _dio.patch(
        '/api/v1/auth/me',
        data: <String, dynamic>{
          if (displayName != null) 'display_name': displayName,
          if (clearUsername)
            'username': null
          else if (username != null)
            'username': username,
        },
        options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      );
    } on DioException catch (error) {
      throw AuthException(
        _firstErrorMessage(error.response?.data) ?? 'Unable to update profile.',
      );
    }
  }

  /// Permanently deletes the signed-in account (DELETE /auth/me).
  ///
  /// The server requires re-auth proof beyond the access token: [password]
  /// for password accounts, or a fresh Google ID token ([googleIdToken]) for
  /// OAuth-only accounts. Exactly one must be given.
  ///
  /// Throws [AuthException] with the server's message on rejection — kept
  /// deliberately vague by the backend — or a generic message on network
  /// failure.
  Future<void> deleteAccount({
    required String accessToken,
    String? password,
    String? googleIdToken,
  }) async {
    try {
      await _dio.delete(
        '/api/v1/auth/me',
        data: <String, dynamic>{
          if (password != null) 'password': password,
          if (googleIdToken != null) 'id_token': googleIdToken,
        },
        options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      );
    } on DioException catch (error) {
      final message = _firstErrorMessage(error.response?.data);
      throw AuthException(
        message ?? 'Could not delete the account. Please try again later.',
      );
    } catch (error, stackTrace) {
      logError('deleteAccount', error, stackTrace);
      throw AuthException(
        'Could not delete the account. Please try again later.',
      );
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
