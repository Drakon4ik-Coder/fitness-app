import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/data/off_rate_limiter.dart';

void main() {
  test('throws when key reused with different type', () async {
    final limiter = OffRateLimiter();
    final completer = Completer<String>();
    final future = limiter.run<String>('same-key', () => completer.future);

    expect(
      () => limiter.run<int>('same-key', () async => 42),
      throwsA(isA<StateError>()),
    );

    completer.complete('done');
    await future;
  });
}
