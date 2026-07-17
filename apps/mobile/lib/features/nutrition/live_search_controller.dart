import 'dart:async';

import 'package:dio/dio.dart';

import 'data/api_exceptions.dart';
import 'data/fatsecret_client.dart';
import 'data/fatsecret_mapper.dart';
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
///   (+ FatSecret, KAN-67) together ([defaultDebounce], D-06; 600ms per
///   KAN-97 — 300ms fired mid-typing);
/// - the active-query [CancelToken] that is cancelled the instant a newer
///   keystroke supersedes it so the in-flight OFF socket is actually aborted
///   (D-08 / SRCH-02);
/// - the 2-char floor applied to every online source (D-07); single-char
///   queries hit none of them (local cache stays the page's job).
///
/// The page keeps the instant, un-debounced local-cache search and feeds this
/// controller's callbacks back into its `setState`-driven result fields.
class LiveSearchController {
  /// Wait after the last keystroke before the online sources fire. 600ms
  /// (KAN-97): 300ms triggered searches while the user was still typing,
  /// wasting the OFF rate budget on queries nobody wanted answered.
  static const Duration defaultDebounce = Duration(milliseconds: 600);

  LiveSearchController({
    required OffClient offClient,
    required FoodsApiService foodsApi,
    required this.onBackendResults,
    required this.onOffResults,
    required this.onLoadingChanged,
    required this.onUnauthorized,
    FatSecretClient? fatsecretClient,
    this.onFatSecretResults,
    OffMapper? offMapper,
    FatSecretMapper? fatsecretMapper,
    OffRateLimiter? rateLimiter,
    Duration debounce = defaultDebounce,
    int minQueryLength = 2,
    String localeLanguage = 'en',
  }) : _offClient = offClient,
       _foodsApi = foodsApi,
       _fatsecretClient = fatsecretClient,
       _offMapper = offMapper ?? OffMapper(),
       _fatsecretMapper = fatsecretMapper ?? FatSecretMapper(),
       _rateLimiter = rateLimiter ?? OffRateLimiter.shared,
       _debounceDuration = debounce,
       _minQueryLength = minQueryLength,
       _localeLanguage = localeLanguage;

  final OffClient _offClient;
  final FoodsApiService _foodsApi;
  // Null = the FatSecret leg is disabled entirely (feature off); no calls,
  // no results, no loading-flag churn.
  final FatSecretClient? _fatsecretClient;
  final OffMapper _offMapper;
  final FatSecretMapper _fatsecretMapper;
  final OffRateLimiter _rateLimiter;
  final Duration _debounceDuration;
  final int _minQueryLength;
  final String _localeLanguage;

  /// Backend typeahead results for the latest non-superseded query.
  final void Function(List<FoodItem> results) onBackendResults;

  /// OFF results (already mapped to [FoodItem]) for the latest query.
  final void Function(List<FoodItem> results) onOffResults;

  /// FatSecret results (already mapped to [FoodItem]) for the latest query.
  /// Both this and [_fatsecretClient] must be non-null for the leg to fire.
  final void Function(List<FoodItem> results)? onFatSecretResults;

  /// Loading-flag updates. Drives the existing thin progress line; never an
  /// error banner (D-01/D-02).
  final void Function({
    required bool backend,
    required bool off,
    required bool fatsecret,
  })
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
  bool _fatsecretLoading = false;

  /// Both the client and its result callback must be supplied, or the
  /// FatSecret leg never fires — a half-wired setup (e.g. a test that forgot
  /// one) is treated the same as the feature being off.
  bool get _fatsecretEnabled =>
      _fatsecretClient != null && onFatSecretResults != null;

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
      _setLoading(backend: false, off: false, fatsecret: false);
      onBackendResults(const []);
      onOffResults(const []);
      // Gated on _fatsecretEnabled, not just callback presence: when the leg
      // is disabled the controller must never touch FatSecret state — a
      // half-wired caller's results are its own, not ours to clear.
      if (_fatsecretEnabled) onFatSecretResults!(const []);
      return;
    }

    // Supersede the previous query's in-flight request at keystroke time, not
    // when the debounce fires (D-08 / SRCH-02): otherwise a late response for
    // the old query can land inside the debounce window, still match
    // `_activeToken`/`_activeQuery`, pass the stale guard, and repopulate the
    // page under a newer visible query.
    _activeToken?.cancel('superseded by "$query"');
    _activeToken = null;
    _activeQuery = query;

    _debounce = Timer(_debounceDuration, () => _runOnlineSearch(query));
  }

  Future<void> _runOnlineSearch(String query) async {
    // Below the floor, no online source fires (D-07). Local cache is the
    // page's responsibility and already ran un-debounced on the keystroke.
    if (query.length < _minQueryLength) {
      _activeToken?.cancel('below 2-char floor');
      _activeToken = null;
      _activeQuery = query;
      _setLoading(backend: false, off: false, fatsecret: false);
      onBackendResults(const []);
      onOffResults(const []);
      // Same _fatsecretEnabled gate as the empty-query clear above.
      if (_fatsecretEnabled) onFatSecretResults!(const []);
      return;
    }

    // Supersede the previous query's in-flight requests before creating a fresh
    // token. Cancelling here both frees rate-limit budget and stops the socket.
    _activeToken?.cancel('superseded by "$query"');
    final token = CancelToken();
    _activeToken = token;
    _activeQuery = query;

    _setLoading(backend: true, off: true, fatsecret: _fatsecretEnabled);
    await Future.wait([
      _runBackend(query, token),
      _runOff(query, token),
      if (_fatsecretEnabled) _runFatSecret(query, token),
    ]);
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
        _setLoading(
          backend: false,
          off: _offLoading,
          fatsecret: _fatsecretLoading,
        );
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
        _setLoading(
          backend: _backendLoading,
          off: false,
          fatsecret: _fatsecretLoading,
        );
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
        _setLoading(
          backend: _backendLoading,
          off: false,
          fatsecret: _fatsecretLoading,
        );
      }
    }
  }

  /// Third live-search leg (KAN-67): restaurant/chain results from FatSecret.
  /// Mirrors `_runOff`'s shape — same pre-flight budget check, same
  /// error-silent live path, same stale guard — but against FatSecret's own
  /// limiter (never OFF's budget). A 401 still routes to logout: this call
  /// goes through our own backend proxy, the same auth gate as typeahead.
  Future<void> _runFatSecret(String query, CancelToken token) async {
    final client = _fatsecretClient;
    if (client == null) return;
    // Same pre-flight silent-skip politeness as OFF (D-01): never spend the
    // call just to catch the throttle throw, and never clear prior results.
    if (client.rateLimiter.timeUntilNextAllowed() != null) {
      if (!_isStale(query, token)) {
        _setLoading(
          backend: _backendLoading,
          off: _offLoading,
          fatsecret: false,
        );
      }
      return;
    }
    try {
      final foods = await client.searchFoods(query, cancelToken: token);
      if (_isStale(query, token)) return;
      final items = foods
          .map(_fatsecretMapper.mapSummary)
          .whereType<FoodItem>()
          .toList();
      onFatSecretResults?.call(items);
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await onUnauthorized();
        return;
      }
      // Live path is error-silent, same as the other two legs.
    } on DioException catch (error) {
      // A superseded/cancelled request must read clean, same as OFF.
      if (CancelToken.isCancel(error)) return;
    } on OffRateLimitException {
      // Budget exhausted mid-flight (raced the pre-flight check above);
      // silent, same as OFF's throttle handling.
    } catch (_) {
      // Defensive catch-all; live path stays error-silent.
    } finally {
      if (!_isStale(query, token)) {
        _setLoading(
          backend: _backendLoading,
          off: _offLoading,
          fatsecret: false,
        );
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

  void _setLoading({
    required bool backend,
    required bool off,
    required bool fatsecret,
  }) {
    if (_backendLoading == backend &&
        _offLoading == off &&
        _fatsecretLoading == fatsecret) {
      return;
    }
    _backendLoading = backend;
    _offLoading = off;
    _fatsecretLoading = fatsecret;
    onLoadingChanged(backend: backend, off: off, fatsecret: fatsecret);
  }

  /// Cancel the pending debounce and abort any in-flight request. Call from the
  /// owning widget's `dispose()`.
  void dispose() {
    _debounce?.cancel();
    _activeToken?.cancel('controller disposed');
    _activeToken = null;
  }
}
