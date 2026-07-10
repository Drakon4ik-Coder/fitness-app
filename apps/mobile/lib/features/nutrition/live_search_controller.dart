import 'dart:async';

import 'package:dio/dio.dart';

import 'data/api_exceptions.dart';
import 'data/food_models.dart';
import 'data/foods_api_service.dart';
import 'data/off_client.dart';
import 'data/off_mapper.dart';
import 'data/off_rate_limiter.dart';

/// Orchestrates live search-as-you-type for the add-food screen.
///
/// Extracted from `_AddFoodPageState` so the timing-sensitive logic (debounce,
/// per-query cancellation, the 2-char floor) is reachable from `flutter_test`
/// without pumping a full widget tree. It is a plain Dart class wired via
/// constructor DI + callbacks, matching the existing `onLoggedIn`/`onLogout`
/// idiom — deliberately NOT a Widget, Riverpod notifier, or
/// ChangeNotifier-as-framework (CLAUDE.md: no Riverpod/go_router).
///
/// Responsibilities (moved out of the page):
/// - the single shared debounce timer that fires backend typeahead + OFF
///   together (~300ms, D-06);
/// - the active-query [CancelToken] that is cancelled the instant a newer
///   keystroke supersedes it so the in-flight OFF socket is actually aborted
///   (D-08 / SRCH-02);
/// - the 2-char floor applied to BOTH online sources (D-07); single-char
///   queries hit neither backend nor OFF (local cache stays the page's job).
///
/// The page keeps the instant, un-debounced local-cache search and feeds this
/// controller's callbacks back into its `setState`-driven result fields.
class LiveSearchController {
  LiveSearchController({
    required OffClient offClient,
    required FoodsApiService foodsApi,
    required this.onBackendResults,
    required this.onOffResults,
    required this.onLoadingChanged,
    required this.onUnauthorized,
    OffMapper? offMapper,
    OffRateLimiter? rateLimiter,
    Duration debounce = const Duration(milliseconds: 300),
    int minQueryLength = 2,
    String localeLanguage = 'en',
  }) : _offClient = offClient,
       _foodsApi = foodsApi,
       _offMapper = offMapper ?? OffMapper(),
       _rateLimiter = rateLimiter ?? OffRateLimiter.shared,
       _debounceDuration = debounce,
       _minQueryLength = minQueryLength,
       _localeLanguage = localeLanguage;

  final OffClient _offClient;
  final FoodsApiService _foodsApi;
  final OffMapper _offMapper;
  final OffRateLimiter _rateLimiter;
  final Duration _debounceDuration;
  final int _minQueryLength;
  final String _localeLanguage;

  /// Backend typeahead results for the latest non-superseded query.
  final void Function(List<FoodItem> results) onBackendResults;

  /// OFF results (already mapped to [FoodItem]) for the latest query.
  final void Function(List<FoodItem> results) onOffResults;

  /// Loading-flag updates. Drives the existing thin progress line; never an
  /// error banner (D-01/D-02).
  final void Function({required bool backend, required bool off})
  onLoadingChanged;

  /// Backend 401 → route to logout (preserves the existing auth gate).
  final Future<void> Function() onUnauthorized;

  Timer? _debounce;
  CancelToken? _activeToken;

  /// The query whose online fetch is currently authoritative. Used as a
  /// belt-and-suspenders stale guard alongside the real CancelToken (D-08):
  /// a late callback for a superseded query is ignored.
  String _activeQuery = '';

  bool _backendLoading = false;
  bool _offLoading = false;

  /// Handle a keystroke. The page calls this on every change after running its
  /// own instant local-cache search. Empty queries clear pending online work;
  /// non-empty queries (re)arm the shared debounce.
  void onQueryChanged(String rawQuery) {
    final query = rawQuery.trim();
    _debounce?.cancel();

    if (query.isEmpty) {
      // Supersede anything in flight and clear online results.
      _activeToken?.cancel('query cleared');
      _activeToken = null;
      _activeQuery = '';
      _setLoading(backend: false, off: false);
      onBackendResults(const []);
      onOffResults(const []);
      return;
    }

    // Supersede the previous query's in-flight request at keystroke time, not
    // when the debounce fires (D-08 / SRCH-02): otherwise a late response for
    // the old query can land inside the 300ms window, still match
    // `_activeToken`/`_activeQuery`, pass the stale guard, and repopulate the
    // page under a newer visible query.
    _activeToken?.cancel('superseded by "$query"');
    _activeToken = null;
    _activeQuery = query;

    _debounce = Timer(_debounceDuration, () => _runOnlineSearch(query));
  }

  Future<void> _runOnlineSearch(String query) async {
    // Below the floor, neither online source fires (D-07). Local cache is the
    // page's responsibility and already ran un-debounced on the keystroke.
    if (query.length < _minQueryLength) {
      _activeToken?.cancel('below 2-char floor');
      _activeToken = null;
      _activeQuery = query;
      _setLoading(backend: false, off: false);
      onBackendResults(const []);
      onOffResults(const []);
      return;
    }

    // Supersede the previous query's in-flight requests before creating a fresh
    // token. Cancelling here both frees rate-limit budget and stops the socket.
    _activeToken?.cancel('superseded by "$query"');
    final token = CancelToken();
    _activeToken = token;
    _activeQuery = query;

    _setLoading(backend: true, off: true);
    await Future.wait([_runBackend(query, token), _runOff(query, token)]);
  }

  Future<void> _runBackend(String query, CancelToken token) async {
    try {
      final results = await _foodsApi.typeahead(query);
      if (_isStale(query, token)) return;
      onBackendResults(results);
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await onUnauthorized();
        return;
      }
      // Live path is error-silent; keep whatever results were already shown.
    } catch (_) {
      // Defensive: never surface backend errors in the live path.
    } finally {
      if (!_isStale(query, token)) {
        _setLoading(backend: false, off: _offLoading);
      }
    }
  }

  Future<void> _runOff(String query, CancelToken token) async {
    // Pre-flight politeness check (D-01): if the limiter's budget is exhausted,
    // skip the OFF call silently rather than firing it and catching the throw.
    // We deliberately do NOT emit any results here — clearing `_offResults`
    // would wipe already-loaded OFF cards mid-typing; the skip must keep prior
    // results visible. The only signal is the thin progress line, which the
    // `finally` below immediately resets to false (a budget-exhausted query is
    // not actually "loading", so the catch-up hint must not stick on).
    //
    // Why no timestamp refund: per RESEARCH Pitfall 1 the spent limiter slot is
    // the intended polite behavior — we never try to "give back" budget. Do not
    // "fix" this by refunding; the silent skip IS the rate-limit response.
    if (_rateLimiter.timeUntilNextAllowed() != null) {
      if (!_isStale(query, token)) {
        _setLoading(backend: _backendLoading, off: false);
      }
      return;
    }
    try {
      final responses = await _search(query, token);
      if (_isStale(query, token)) return;
      final items = responses
          .map(
            (response) => _offMapper.mapProduct(
              product: response.product,
              rawJson: response.rawJson,
              localeLanguage: _localeLanguage,
            ),
          )
          .toList();
      onOffResults(items);
    } on DioException catch (error) {
      // A superseded/cancelled OFF request must read clean — swallow it, never
      // surface as an error (D-01/D-02 / SRCH-02 happy path).
      if (CancelToken.isCancel(error)) return;
      // Other OFF transport errors are also swallowed in the live path.
    } on OffRateLimitException {
      // Throttle is silent in the live path (D-02); the progress line is the
      // only hint. Full silent-skip hardening lands in plan 01-02.
    } on OffException {
      // Live-search OFF errors do not surface as a banner (D-02).
    } catch (_) {
      // Defensive catch-all; live path stays error-silent.
    } finally {
      if (!_isStale(query, token)) {
        _setLoading(backend: _backendLoading, off: false);
      }
    }
  }

  /// Forwards the active query + its CancelToken to OFF. Isolated so the
  /// token-threading call stays on one readable line.
  Future<List<OffProductResponse>> _search(String query, CancelToken token) {
    return _offClient.searchProducts(query, cancelToken: token);
  }

  /// A query is stale if a newer query has superseded it (token cancelled or
  /// active query moved on). Late callbacks for a stale query are dropped.
  bool _isStale(String query, CancelToken token) {
    return token.isCancelled ||
        !identical(token, _activeToken) ||
        _activeQuery != query;
  }

  void _setLoading({required bool backend, required bool off}) {
    if (_backendLoading == backend && _offLoading == off) return;
    _backendLoading = backend;
    _offLoading = off;
    onLoadingChanged(backend: backend, off: off);
  }

  /// Cancel the pending debounce and abort any in-flight request. Call from the
  /// owning widget's `dispose()`.
  void dispose() {
    _debounce?.cancel();
    _activeToken?.cancel('controller disposed');
    _activeToken = null;
  }
}
