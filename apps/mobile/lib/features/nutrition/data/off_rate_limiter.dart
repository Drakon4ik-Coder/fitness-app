class OffRateLimitException implements Exception {
  OffRateLimitException(this.retryAfter);

  final Duration retryAfter;

  String get message {
    final seconds = retryAfter.inSeconds;
    if (seconds <= 1) {
      return 'OpenFoodFacts is temporarily rate limited. Try again in a moment.';
    }
    return 'OpenFoodFacts is temporarily rate limited. Try again in ${seconds}s.';
  }

  @override
  String toString() => message;
}

class OffRateLimiter {
  OffRateLimiter({
    this.maxCalls = 9,
    this.window = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static final OffRateLimiter shared = OffRateLimiter();

  final int maxCalls;
  final Duration window;
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

  Future<T> run<T>(String key, Future<T> Function() action) {
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
      );
    }
    final future = action();
    _timestamps.add(now);
    _inFlight[key] = future;
    future.whenComplete(() {
      _inFlight.remove(key);
    });
    return future;
  }

  void _prune(DateTime now) {
    _timestamps.removeWhere((timestamp) => now.difference(timestamp) >= window);
  }
}
