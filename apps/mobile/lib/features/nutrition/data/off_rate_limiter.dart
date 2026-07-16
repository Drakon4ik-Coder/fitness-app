import 'dart:async' show unawaited;

class OffRateLimitException implements Exception {
  // [serviceName] defaults to 'OpenFoodFacts' so every existing call site
  // (and its tests) keeps the exact same message; a limiter fronting a
  // different partner (e.g. FatSecret, KAN-67) passes its own name instead.
  OffRateLimitException(this.retryAfter, [this.serviceName = 'OpenFoodFacts']);

  final Duration retryAfter;
  final String serviceName;

  String get message {
    final seconds = retryAfter.inSeconds;
    if (seconds <= 1) {
      return '$serviceName is temporarily rate limited. Try again in a moment.';
    }
    return '$serviceName is temporarily rate limited. Try again in ${seconds}s.';
  }

  @override
  String toString() => message;
}

class OffRateLimiter {
  OffRateLimiter({
    this.maxCalls = 9,
    this.window = const Duration(seconds: 60),
    String serviceName = 'OpenFoodFacts',
    DateTime Function()? now,
  }) : _serviceName = serviceName,
       _now = now ?? DateTime.now;

  static final OffRateLimiter shared = OffRateLimiter();

  final int maxCalls;
  final Duration window;
  final String _serviceName;
  final DateTime Function() _now;
  final List<DateTime> _timestamps = [];
  final Map<String, Future<dynamic>> _inFlight = {};

  Duration? timeUntilNextAllowed() {
    final now = _now();
    _prune(now);
    if (_timestamps.length < maxCalls) {
      return null;
    }
    final oldest = _timestamps.first;
    final remaining = window - now.difference(oldest);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Future<T> run<T>(String key, Future<T> Function() action) async {
    final existing = _inFlight[key];
    if (existing != null) {
      if (existing is Future<T>) {
        return existing;
      }
      throw StateError('Rate limiter key reused with a different type.');
    }
    final now = _now();
    _prune(now);
    if (_timestamps.length >= maxCalls) {
      final oldest = _timestamps.first;
      final retryAfter = window - now.difference(oldest);
      throw OffRateLimitException(
        retryAfter.isNegative ? Duration.zero : retryAfter,
        _serviceName,
      );
    }
    final future = action();
    _timestamps.add(now);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      unawaited(_inFlight.remove(key));
    }
  }

  void _prune(DateTime now) {
    _timestamps.removeWhere((timestamp) => now.difference(timestamp) >= window);
  }
}
