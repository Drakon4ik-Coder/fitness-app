import 'package:flutter/foundation.dart' show debugPrint;

/// App-wide sink for the original error behind every user-friendly message.
///
/// Null by default; `main.dart` assigns it once when Sentry is enabled
/// (non-local build with a DSN) so every swallowed error becomes a
/// breadcrumb. In local runs and tests it stays null.
void Function(String context, Object error, StackTrace stackTrace)?
appErrorLogger;

/// Records an error that is about to be converted into a friendly message or
/// silently degraded. Without a configured [appErrorLogger] it debug-prints
/// in debug builds and is silent in release — the visible behavior is
/// unchanged, but the diagnostic trail no longer dead-ends.
void logError(String context, Object error, StackTrace stackTrace) {
  final log = appErrorLogger;
  if (log != null) {
    log(context, error, stackTrace);
    return;
  }
  assert(() {
    debugPrint('Error [$context]: $error');
    return true;
  }());
}
