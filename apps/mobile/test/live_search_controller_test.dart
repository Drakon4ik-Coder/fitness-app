import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/foods_api_service.dart';
import 'package:fitness_app/features/nutrition/data/off_client.dart';
import 'package:fitness_app/features/nutrition/data/off_rate_limiter.dart';
import 'package:fitness_app/features/nutrition/live_search_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hand-rolled fake backend typeahead source (no mocking lib). Records calls
/// and lets a test control when each typeahead future completes.
class _FakeFoodsApi extends FoodsApiService {
  _FakeFoodsApi() : super(accessToken: 'test-token');

  final List<String> typeaheadQueries = [];
  Completer<List<FoodItem>>? pending;

  @override
  Future<List<FoodItem>> typeahead(String query, {int limit = 10}) {
    typeaheadQueries.add(query);
    final completer = Completer<List<FoodItem>>();
    pending = completer;
    return completer.future;
  }
}

/// Hand-rolled fake OFF client. Records the query + the CancelToken it was
/// handed, and resolves only when the test completes it — so the controller can
/// supersede an in-flight request and the test can assert the prior token was
/// cancelled.
///
/// A test may set [throwOnSearch] to make `searchProducts` reject with a given
/// error instead of completing via [pending], so the swallow behavior (D-02)
/// can be exercised without wiring a real Dio transport.
class _FakeOffClient extends OffClient {
  _FakeOffClient() : super(dio: Dio(), rateLimiter: OffRateLimiter());

  final List<String> searchQueries = [];
  final List<CancelToken?> tokens = [];
  Completer<List<OffProductResponse>>? pending;
  Object? throwOnSearch;

  @override
  Future<List<OffProductResponse>> searchProducts(
    String query, {
    int pageSize = 10,
    String? categoryTag,
    CancelToken? cancelToken,
  }) {
    searchQueries.add(query);
    tokens.add(cancelToken);
    final error = throwOnSearch;
    if (error != null) {
      return Future<List<OffProductResponse>>.error(error);
    }
    final completer = Completer<List<OffProductResponse>>();
    pending = completer;
    return completer.future;
  }
}

/// Rate limiter stub whose `timeUntilNextAllowed()` is forced to a fixed value,
/// so a test can simulate an exhausted budget (non-null) deterministically
/// without pre-spending real timestamps.
class _StubRateLimiter extends OffRateLimiter {
  _StubRateLimiter(this._timeUntilNextAllowed);

  final Duration? _timeUntilNextAllowed;

  @override
  Duration? timeUntilNextAllowed() => _timeUntilNextAllowed;
}

LiveSearchController _build({
  required _FakeOffClient off,
  required _FakeFoodsApi backend,
  List<FoodItem> Function(List<FoodItem>)? onBackend,
  List<FoodItem> Function(List<FoodItem>)? onOff,
  void Function()? onUnauthorized,
  OffRateLimiter? rateLimiter,
  void Function({required bool backend, required bool off})? onLoadingChanged,
}) {
  return LiveSearchController(
    offClient: off,
    foodsApi: backend,
    rateLimiter: rateLimiter ?? OffRateLimiter(),
    onBackendResults: (results) => onBackend?.call(results),
    onOffResults: (results) => onOff?.call(results),
    onLoadingChanged: ({required bool backend, required bool off}) =>
        onLoadingChanged?.call(backend: backend, off: off),
    onUnauthorized: () async => onUnauthorized?.call(),
  );
}

void main() {
  test(
    'debounce coalesces rapid keystrokes into a single online fetch (D-06)',
    () {
      fakeAsync((async) {
        final off = _FakeOffClient();
        final backend = _FakeFoodsApi();
        final controller = _build(off: off, backend: backend);

        controller.onQueryChanged('a');
        controller.onQueryChanged('ap');
        // Nothing fires before the debounce elapses.
        async.elapse(const Duration(milliseconds: 299));
        expect(off.searchQueries, isEmpty);
        expect(backend.typeaheadQueries, isEmpty);

        async.elapse(const Duration(milliseconds: 1));
        // Exactly one online fetch, for the latest query.
        expect(off.searchQueries, ['ap']);
        expect(backend.typeaheadQueries, ['ap']);

        controller.dispose();
      });
    },
  );

  test(
    '2-char floor skips both online sources for single-char queries (D-07)',
    () {
      fakeAsync((async) {
        final off = _FakeOffClient();
        final backend = _FakeFoodsApi();
        final controller = _build(off: off, backend: backend);

        controller.onQueryChanged('a');
        async.elapse(const Duration(milliseconds: 300));
        expect(off.searchQueries, isEmpty);
        expect(backend.typeaheadQueries, isEmpty);

        controller.onQueryChanged('ap');
        async.elapse(const Duration(milliseconds: 300));
        expect(off.searchQueries, ['ap']);
        expect(backend.typeaheadQueries, ['ap']);

        controller.dispose();
      });
    },
  );

  test('superseding a query cancels the prior CancelToken before the new one '
      'is created (D-08)', () {
    fakeAsync((async) {
      final off = _FakeOffClient();
      final backend = _FakeFoodsApi();
      final controller = _build(off: off, backend: backend);

      controller.onQueryChanged('apple');
      async.elapse(const Duration(milliseconds: 300));
      expect(off.tokens.length, 1);
      final firstToken = off.tokens[0]!;
      expect(firstToken.isCancelled, isFalse);

      // A newer query supersedes the first before it resolves.
      controller.onQueryChanged('apples');
      async.elapse(const Duration(milliseconds: 300));
      expect(off.tokens.length, 2);
      final secondToken = off.tokens[1]!;

      expect(
        firstToken.isCancelled,
        isTrue,
        reason: 'prior token must be cancelled on supersede',
      );
      expect(secondToken.isCancelled, isFalse);
      expect(identical(firstToken, secondToken), isFalse);

      controller.dispose();
    });
  });

  test(
    'a late OFF result for a superseded query is dropped (stale-guard, D-08)',
    () {
      fakeAsync((async) {
        final off = _FakeOffClient();
        final backend = _FakeFoodsApi();
        final offResultsReceived = <List<FoodItem>>[];
        final controller = _build(
          off: off,
          backend: backend,
          onOff: (results) {
            offResultsReceived.add(results);
            return results;
          },
        );

        controller.onQueryChanged('apple');
        async.elapse(const Duration(milliseconds: 300));
        final firstPending = off.pending!;

        // Supersede with a newer query.
        controller.onQueryChanged('apples');
        async.elapse(const Duration(milliseconds: 300));

        // The first (superseded) query now resolves late with a product.
        firstPending.complete([
          OffProductResponse(
            product: <String, dynamic>{
              'code': '111',
              'product_name': 'Stale Apple',
              'lang': 'en',
            },
            rawJson: '{}',
          ),
        ]);
        async.flushMicrotasks();

        // The stale result must NOT have been emitted.
        expect(
          offResultsReceived,
          isEmpty,
          reason: 'late result for superseded query must be ignored',
        );

        controller.dispose();
      });
    },
  );

  test('a newer keystroke cancels the in-flight request immediately — a late '
      'result arriving inside the new debounce window is dropped (D-08)', () {
    fakeAsync((async) {
      final off = _FakeOffClient();
      final backend = _FakeFoodsApi();
      final backendResultsReceived = <List<FoodItem>>[];
      final offResultsReceived = <List<FoodItem>>[];
      final controller = _build(
        off: off,
        backend: backend,
        onBackend: (results) {
          backendResultsReceived.add(results);
          return results;
        },
        onOff: (results) {
          offResultsReceived.add(results);
          return results;
        },
      );

      controller.onQueryChanged('apple');
      async.elapse(const Duration(milliseconds: 300));
      final firstToken = off.tokens[0]!;
      final firstOffPending = off.pending!;
      final firstBackendPending = backend.pending!;

      // Supersede WITHOUT elapsing the new debounce: the keystroke itself
      // must cancel the in-flight token, not the debounce firing 300ms
      // later.
      controller.onQueryChanged('apples');
      expect(
        firstToken.isCancelled,
        isTrue,
        reason: 'keystroke must cancel the in-flight token instantly',
      );

      // Both old-query responses resolve inside the debounce window; the
      // stale guard must drop them.
      firstOffPending.complete([
        OffProductResponse(
          product: <String, dynamic>{
            'code': '111',
            'product_name': 'Stale Apple',
            'lang': 'en',
          },
          rawJson: '{}',
        ),
      ]);
      firstBackendPending.complete(const []);
      async.flushMicrotasks();

      expect(
        offResultsReceived,
        isEmpty,
        reason: 'late OFF result inside the debounce window must be dropped',
      );
      expect(
        backendResultsReceived,
        isEmpty,
        reason:
            'late backend result inside the debounce window must be dropped',
      );

      controller.dispose();
    });
  });

  test(
    'budget-exhausted: a debounced query skips the OFF call entirely, emits no '
    'error, and keeps prior OFF results intact (pre-flight skip, D-01)',
    () {
      fakeAsync((async) {
        final off = _FakeOffClient();
        final backend = _FakeFoodsApi();
        final offResultsReceived = <List<FoodItem>>[];
        final controller = _build(
          off: off,
          backend: backend,
          rateLimiter: _StubRateLimiter(const Duration(seconds: 5)),
          onOff: (results) {
            offResultsReceived.add(results);
            return results;
          },
        );

        controller.onQueryChanged('yogurt');
        async.elapse(const Duration(milliseconds: 300));

        // OFF was never called — the pre-flight check short-circuited it.
        expect(
          off.searchQueries,
          isEmpty,
          reason: 'exhausted budget must skip searchProducts entirely',
        );
        // No OFF result callback fired — prior _offResults stay untouched (the
        // skip must NOT clear already-loaded results).
        expect(
          offResultsReceived,
          isEmpty,
          reason: 'silent skip must not push an empty (clearing) result list',
        );

        controller.dispose();
      });
    },
  );

  test('budget-exhausted skip resets the OFF loading flag to false (no stuck '
      'progress line, D-01)', () {
    fakeAsync((async) {
      final off = _FakeOffClient();
      final backend = _FakeFoodsApi();
      final offLoadingStates = <bool>[];
      final controller = _build(
        off: off,
        backend: backend,
        rateLimiter: _StubRateLimiter(const Duration(seconds: 5)),
        onLoadingChanged: ({required bool backend, required bool off}) =>
            offLoadingStates.add(off),
      );

      controller.onQueryChanged('yogurt');
      async.elapse(const Duration(milliseconds: 300));
      async.flushMicrotasks();

      // The OFF loading flag must have settled back to false — a skipped query
      // can never leave the thin progress line stuck on.
      expect(
        offLoadingStates.isNotEmpty && offLoadingStates.last,
        isFalse,
        reason: 'OFF loading flag must reset to false after a silent skip',
      );

      controller.dispose();
    });
  });

  test('OffRateLimitException from searchProducts is swallowed: no error '
      'emitted, backend results still flow (D-02)', () {
    fakeAsync((async) {
      final off = _FakeOffClient()
        ..throwOnSearch = OffRateLimitException(const Duration(seconds: 3));
      final backend = _FakeFoodsApi();
      final backendResultsReceived = <List<FoodItem>>[];
      final offResultsReceived = <List<FoodItem>>[];
      final controller = _build(
        off: off,
        backend: backend,
        onBackend: (results) {
          backendResultsReceived.add(results);
          return results;
        },
        onOff: (results) {
          offResultsReceived.add(results);
          return results;
        },
      );

      controller.onQueryChanged('yogurt');
      async.elapse(const Duration(milliseconds: 300));
      async.flushMicrotasks();

      // Backend completes normally and its results still flow through.
      backend.pending!.complete(const []);
      async.flushMicrotasks();

      // The rate-limit throw was swallowed: no OFF result list (error-silent),
      // and certainly no exception bubbled out of the controller.
      expect(off.searchQueries, ['yogurt']);
      expect(
        offResultsReceived,
        isEmpty,
        reason: 'OffRateLimitException must be swallowed, not surfaced',
      );
      expect(
        backendResultsReceived,
        isNotEmpty,
        reason: 'backend results must still flow when OFF throttles',
      );

      controller.dispose();
    });
  });

  test('a non-cancel OffException from searchProducts is swallowed silently in '
      'the live path (D-02)', () {
    fakeAsync((async) {
      final off = _FakeOffClient()
        ..throwOnSearch = OffException('Unable to search OFF.');
      final backend = _FakeFoodsApi();
      final offResultsReceived = <List<FoodItem>>[];
      final offLoadingStates = <bool>[];
      final controller = _build(
        off: off,
        backend: backend,
        onOff: (results) {
          offResultsReceived.add(results);
          return results;
        },
        onLoadingChanged: ({required bool backend, required bool off}) =>
            offLoadingStates.add(off),
      );

      controller.onQueryChanged('yogurt');
      async.elapse(const Duration(milliseconds: 300));
      async.flushMicrotasks();

      // The OFF error never surfaces as a result/error and the loading flag
      // resets so the progress line is not left stuck on.
      expect(off.searchQueries, ['yogurt']);
      expect(
        offResultsReceived,
        isEmpty,
        reason: 'live-path OffException must be swallowed, not surfaced',
      );
      expect(
        offLoadingStates.isNotEmpty && offLoadingStates.last,
        isFalse,
        reason: 'OFF loading flag must reset to false after a swallowed error',
      );

      controller.dispose();
    });
  });
}
