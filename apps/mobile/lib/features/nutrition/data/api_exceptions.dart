import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.isNetworkError = false});

  final String message;
  final int? statusCode;

  /// True when the request never got an HTTP response (offline, DNS failure,
  /// timeout) — the class of failures worth queueing for replay (KAN-28), as
  /// opposed to a server verdict like a 4xx that would just fail again.
  final bool isNetworkError;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

/// Sink for the original error behind every user-friendly [ApiException].
/// Null by default; wire this to a crash reporter once the app has one so
/// swallowed errors become breadcrumbs instead of vanishing.
void Function(String context, Object error, StackTrace stackTrace)?
apiErrorLogger;

/// Records the original error before it is converted to a friendly message.
/// Without a configured [apiErrorLogger] it debug-prints in debug builds and
/// is silent in release — same visible behavior as before, but no longer a
/// dead end for diagnostics.
void logApiError(String context, Object error, StackTrace stackTrace) {
  final log = apiErrorLogger;
  if (log != null) {
    log(context, error, stackTrace);
    return;
  }
  assert(() {
    debugPrint('API error [$context]: $error');
    return true;
  }());
}

/// Runs [request] and converts any failure into an [ApiException] carrying
/// [friendlyMessage] — the one place the Dio→ApiException mapping lives.
///
/// [ApiException]s thrown inside [request] (e.g. unexpected-shape guards)
/// pass through untouched. The `isNetworkError` classification — no HTTP
/// response means offline/DNS/timeout, the class of failures worth replaying,
/// as opposed to a server verdict that would just fail again — feeds the
/// offline outbox (KAN-28); preserve it exactly.
Future<T> mapApiErrors<T>(
  String friendlyMessage,
  Future<T> Function() request,
) async {
  try {
    return await request();
  } on ApiException {
    rethrow;
  } on DioException catch (error, stackTrace) {
    logApiError(friendlyMessage, error, stackTrace);
    throw ApiException(
      friendlyMessage,
      statusCode: error.response?.statusCode,
      isNetworkError: error.response == null,
    );
  } catch (error, stackTrace) {
    logApiError(friendlyMessage, error, stackTrace);
    throw ApiException(friendlyMessage);
  }
}
