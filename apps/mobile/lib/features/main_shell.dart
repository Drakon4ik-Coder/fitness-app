import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/access_token_claims.dart';
import '../core/auth_interceptor.dart';
import '../core/auth_service.dart';
import '../ui_system/lumina_health_theme.dart';
import '../ui_system/tokens.dart';
import 'nutrition/account_page.dart';
import 'nutrition/data/api_exceptions.dart';
import 'nutrition/data/food_local_db.dart';
import 'nutrition/data/foods_api_service.dart';
import 'nutrition/data/local_db_paths.dart';
import 'nutrition/data/nutrition_api_service.dart';
import 'nutrition/data/nutrition_local_store.dart';
import 'nutrition/data/off_client.dart';
import 'nutrition/data/preferences_api_service.dart';
import 'nutrition/data/user_preferences.dart';
import 'nutrition/nutrition_today_page.dart';

/// The signed-in home: a bottom-nav shell hosting the nutrition day (tracking)
/// and the account/settings tabs. It owns the shared [UserPreferences] so a goal
/// edited on the account tab immediately re-targets the today tab's macros.
class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.accessToken,
    required this.onLogout,
    this.authInterceptor,
    // Injectables — real services are created by default; tests pass fakes.
    this.preferencesApi,
    this.authService,
    this.nutritionApi,
    this.foodsApi,
    this.localStore,
    this.offClient,
    this.localDb,
  });

  final String accessToken;
  final Future<void> Function() onLogout;
  final AuthInterceptor? authInterceptor;
  final PreferencesApiService? preferencesApi;
  final AuthService? authService;
  final NutritionApiService? nutritionApi;
  final FoodsApiService? foodsApi;
  final NutritionLocalStore? localStore;
  final OffClient? offClient;
  final FoodLocalDb? localDb;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  late final PreferencesApiService _preferencesApi;
  late final NutritionLocalStore _localStore;
  late final bool _ownsLocalStore;
  late final FoodLocalDb _localDb;
  late final bool _ownsLocalDb;

  // Shared goals/units; null until loaded (or if the fetch fails), in which case
  // the today tab falls back to catalog defaults.
  UserPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _preferencesApi =
        widget.preferencesApi ??
        PreferencesApiService(
          accessToken: widget.accessToken,
          authInterceptor: widget.authInterceptor,
        );
    // Both local DBs are namespaced by the token's user id (KAN-64) so
    // offline data survives logout without being reachable from another
    // account. The shell owns them so the deletion wipe hits the same files
    // the pages write to.
    final userId = userIdFromAccessToken(widget.accessToken);
    _ownsLocalStore = widget.localStore == null;
    _localStore = widget.localStore ?? NutritionLocalStore(userId: userId);
    _ownsLocalDb = widget.localDb == null;
    _localDb = widget.localDb ?? FoodLocalDb(userId: userId);
    if (_ownsLocalStore && userId != null) {
      // Storage cap for shared devices; failures never matter at startup.
      unawaited(evictStaleUserDbs(currentUserId: userId).catchError((_) {}));
    }
    _loadPreferences();
  }

  @override
  void didUpdateWidget(covariant MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accessToken != widget.accessToken) {
      _preferencesApi.updateToken(widget.accessToken);
    }
  }

  @override
  void dispose() {
    if (_ownsLocalStore) _localStore.close();
    if (_ownsLocalDb) _localDb.close();
    super.dispose();
  }

  // Best-effort: a failure just leaves the today tab on its catalog defaults.
  Future<void> _loadPreferences() async {
    try {
      final prefs = await _preferencesApi.fetch();
      if (!mounted) return;
      setState(() => _prefs = prefs);
    } on ApiException {
      // Ignore — catalog defaults are a fine fallback.
    }
  }

  // Logout deliberately keeps both local DBs (KAN-64): they're namespaced per
  // user id, so nothing in them is reachable from another account, and an
  // unsynced offline outbox survives a re-login instead of being lost.

  /// Account deletion (KAN-42): the server data is gone, so scrub every local
  /// trace — both SQLite DBs, then the tokens in secure storage via
  /// [MainShell.onLogout].
  Future<void> _handleAccountDeleted() async {
    try {
      await _localStore.clear();
    } catch (_) {
      // Best-effort — never block sign-out on a cache wipe.
    }
    try {
      await _localDb.clear();
    } catch (_) {
      // Best-effort.
    }
    await widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          NutritionTodayPage(
            accessToken: widget.accessToken,
            onLogout: widget.onLogout,
            authInterceptor: widget.authInterceptor,
            preferences: _prefs,
            nutritionApi: widget.nutritionApi,
            foodsApi: widget.foodsApi,
            localStore: _localStore,
            offClient: widget.offClient,
            localDb: _localDb,
          ),
          AccountPage(
            accessToken: widget.accessToken,
            authInterceptor: widget.authInterceptor,
            preferencesApi: _preferencesApi,
            authService: widget.authService,
            initialPreferences: _prefs,
            onLogout: widget.onLogout,
            onAccountDeleted: _handleAccountDeleted,
            onSaved: (prefs) => setState(() => _prefs = prefs),
          ),
        ],
      ),
      bottomNavigationBar: _ShellNavBar(
        index: _index,
        onSelect: (i) => setState(() => _index = i),
      ),
    );
  }
}

class _ShellNavBar extends StatelessWidget {
  const _ShellNavBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(top: BorderSide(color: LuminaHealthColors.hairline)),
      ),
      child: SafeArea(
        top: false,
        // No fixed bar height: each item enforces a 64px minimum but grows
        // with the label at large system font sizes (KAN-62).
        child: Row(
          children: [
            _ShellNavItem(
              asset: 'assets/bar/track.svg',
              label: 'Nutrition',
              selected: index == 0,
              onTap: () => onSelect(0),
            ),
            _ShellNavItem(
              asset: 'assets/bar/settings.svg',
              label: 'Settings',
              selected: index == 1,
              onTap: () => onSelect(1),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShellNavItem extends StatelessWidget {
  const _ShellNavItem({
    required this.asset,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String asset;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? LuminaHealthColors.primary
        : theme.colorScheme.onSurfaceVariant;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          onTap: onTap,
          // The Semantics wrapper above carries the label; excluding the
          // child keeps TalkBack from announcing it twice.
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SvgPicture.asset(
                      asset,
                      height: 24,
                      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
