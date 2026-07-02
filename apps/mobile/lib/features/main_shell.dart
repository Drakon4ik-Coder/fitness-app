import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/auth_interceptor.dart';
import '../core/auth_service.dart';
import '../ui_system/lumina_health_theme.dart';
import '../ui_system/tokens.dart';
import 'nutrition/account_page.dart';
import 'nutrition/data/api_exceptions.dart';
import 'nutrition/data/food_local_db.dart';
import 'nutrition/data/foods_api_service.dart';
import 'nutrition/data/nutrition_api_service.dart';
import 'nutrition/data/nutrition_day_cache.dart';
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
    this.dayCache,
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
  final NutritionDayCache? dayCache;
  final OffClient? offClient;
  final FoodLocalDb? localDb;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  late final PreferencesApiService _preferencesApi;
  late final NutritionDayCache _dayCache;
  late final bool _ownsDayCache;

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
    _ownsDayCache = widget.dayCache == null;
    _dayCache = widget.dayCache ?? NutritionDayCache();
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
    if (_ownsDayCache) _dayCache.close();
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

  /// Logout from the account tab: wipe the local day cache first so the next
  /// user on this device can't briefly see the previous user's log. (The today
  /// tab wraps [widget.onLogout] with the same wipe on its own auth-gate path.)
  Future<void> _handleLogout() async {
    try {
      await _dayCache.clear();
    } catch (_) {
      // Best-effort — never block logout on a cache wipe.
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
            dayCache: _dayCache,
            offClient: widget.offClient,
            localDb: widget.localDb,
          ),
          AccountPage(
            accessToken: widget.accessToken,
            authInterceptor: widget.authInterceptor,
            preferencesApi: _preferencesApi,
            authService: widget.authService,
            initialPreferences: _prefs,
            onLogout: _handleLogout,
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
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
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
    final scheme = Theme.of(context).colorScheme;
    // The SVGs bake in their own label; tint the whole glyph by selection state.
    final color = selected
        ? LuminaHealthColors.primary
        : scheme.onSurfaceVariant;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Center(
              child: SvgPicture.asset(
                asset,
                height: 30,
                colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
