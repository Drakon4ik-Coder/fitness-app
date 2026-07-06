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
