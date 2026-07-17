import 'package:dio/dio.dart';

import 'environment.dart';

/// Fetches the backend's minimum supported Android build number
/// (`min_supported_build` on `/health/`) for the forced-update gate
/// (KAN-100).
///
/// Failures surface as raw [DioException]/[FormatException] rather than an
/// `ApiException`: the sole caller (`UpdateGate`) fails open on *every*
/// failure — offline and server verdicts alike — so the outbox's
/// offline-vs-verdict classification has no meaning here.
class VersionCheckService {
  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _receiveTimeout = Duration(seconds: 20);

  VersionCheckService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: EnvironmentConfig.apiBaseUrl,
              connectTimeout: _connectTimeout,
              receiveTimeout: _receiveTimeout,
            ),
          );

  final Dio _dio;

  /// Returns the minimum supported versionCode; 0 means forced updates are
  /// disabled server-side.
  Future<int> fetchMinSupportedBuild() async {
    final response = await _dio.get<Map<String, dynamic>>('/health/');
    final value = response.data?['min_supported_build'];
    // A backend predating the field is a definitive "no minimum", not an
    // error — it must never block anyone.
    if (value == null) return 0;
    if (value is int) return value;
    throw FormatException('Unexpected min_supported_build: $value');
  }
}
