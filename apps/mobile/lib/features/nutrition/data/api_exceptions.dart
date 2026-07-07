import 'package:dio/dio.dart';

import '../../../core/app_log.dart';

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
    logError(friendlyMessage, error, stackTrace);
    throw ApiException(
      friendlyMessage,
      statusCode: error.response?.statusCode,
      isNetworkError: error.response == null,
    );
  } catch (error, stackTrace) {
    logError(friendlyMessage, error, stackTrace);
    throw ApiException(friendlyMessage);
  }
}
