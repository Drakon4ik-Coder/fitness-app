import 'package:flutter/material.dart';

import '../../core/auth_interceptor.dart';
import '../../core/auth_service.dart';
import '../../ui_components/ui_components.dart';
import '../../ui_system/lumina_health_theme.dart';
import '../../ui_system/tokens.dart';
import 'data/nutrient_catalog.dart';
import 'data/preferences_api_service.dart';
import 'data/user_preferences.dart';
import 'settings/focus_nutrients_settings_page.dart';
import 'settings/goals_settings_page.dart';
import 'settings/profile_settings_page.dart';
import 'settings/units_settings_page.dart';

/// The settings hub: a nested navigation structure where each row pushes a
/// focused sub-page (Profile, Units, Daily goals) instead of one long form.
/// Rows summarize their current values so the hub doubles as an overview.
///
/// The hub owns the latest [UserPreferences] snapshot; sub-pages pop with the
/// server's updated snapshot after a save. As a tab (onSaved set) the update is
/// handed up so the today tab can refresh its goals; as a pushed route the hub
/// pops with the result instead, matching the old single-page contract.
class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    required this.accessToken,
    required this.preferencesApi,
    required this.onLogout,
    this.authInterceptor,
    this.authService,
    this.initialPreferences,
    this.onSaved,
  });

  final String accessToken;
  final PreferencesApiService preferencesApi;
  final Future<void> Function() onLogout;
  final AuthInterceptor? authInterceptor;
  final AuthService? authService;

  /// The goals/units already loaded by the caller, shown in the row summaries
  /// so the hub isn't blank on open. Null when the caller hasn't loaded them.
  final UserPreferences? initialPreferences;

  /// Called with the server's updated snapshot after a sub-page save. Set by
  /// the shell (where this is a tab, not a pushed route) so the today tab can
  /// refresh its goals. When null, a save pops the route with the result.
  final ValueChanged<UserPreferences>? onSaved;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  late final AuthService _authService;

  /// Set once a sub-page saves; until then row summaries follow the caller's
  /// (possibly late-loading) [AccountPage.initialPreferences].
  UserPreferences? _prefsOverride;

  String _email = '';
  String _displayName = '';
  String _username = '';

  UserPreferences get _prefs =>
      _prefsOverride ?? widget.initialPreferences ?? const UserPreferences();

  @override
  void initState() {
    super.initState();
    // The interceptor matters here: as an eagerly-built tab this fetch runs at
    // startup, when the stored access token may be expired — without it the
    // 401 fails silently and the profile row stays blank.
    _authService =
        widget.authService ??
        AuthService(authInterceptor: widget.authInterceptor);
    _loadAccount();
  }

  Future<void> _loadAccount() async {
    final info = await _authService.fetchMe(accessToken: widget.accessToken);
    if (!mounted || info == null) return;
    setState(() {
      _email = info.email;
      _displayName = info.displayName;
      _username = info.username;
    });
  }

  void _applyUpdatedPrefs(UserPreferences updated) {
    setState(() => _prefsOverride = updated);
    if (widget.onSaved != null) {
      widget.onSaved!(updated);
    } else {
      Navigator.of(context).pop(updated);
    }
  }

  Future<void> _openProfile() async {
    final updated = await Navigator.of(context).push<AccountInfo>(
      MaterialPageRoute(
        builder: (_) => ProfileSettingsPage(
          accessToken: widget.accessToken,
          authService: _authService,
          initialDisplayName: _displayName,
          initialUsername: _username,
          email: _email,
        ),
      ),
    );
    if (updated != null && mounted) {
      setState(() {
        _displayName = updated.displayName;
        _username = updated.username;
        _email = updated.email;
      });
    }
  }

  Future<void> _openUnits() async {
    final updated = await Navigator.of(context).push<UserPreferences>(
      MaterialPageRoute(
        builder: (_) => UnitsSettingsPage(
          preferencesApi: widget.preferencesApi,
          initialPreferences: _prefs,
        ),
      ),
    );
    if (updated != null && mounted) _applyUpdatedPrefs(updated);
  }

  Future<void> _openGoals() async {
    final updated = await Navigator.of(context).push<UserPreferences>(
      MaterialPageRoute(
        builder: (_) => GoalsSettingsPage(
          preferencesApi: widget.preferencesApi,
          initialPreferences: _prefs,
        ),
      ),
    );
    if (updated != null && mounted) _applyUpdatedPrefs(updated);
  }

  Future<void> _openFocusNutrients() async {
    final updated = await Navigator.of(context).push<UserPreferences>(
      MaterialPageRoute(
        builder: (_) => FocusNutrientsSettingsPage(
          preferencesApi: widget.preferencesApi,
          initialPreferences: _prefs,
        ),
      ),
    );
    if (updated != null && mounted) _applyUpdatedPrefs(updated);
  }

  String get _profileSummary {
    if (_displayName.isEmpty && _email.isEmpty) return 'Name and email';
    if (_displayName.isEmpty) return _email;
    if (_email.isEmpty) return _displayName;
    return '$_displayName · $_email';
  }

  String get _unitsSummary {
    // Display labels for stored values (e.g. `kj` → `kJ`).
    const energyLabels = {'kcal': 'kcal', 'kj': 'kJ'};
    final p = _prefs;
    final energy = energyLabels[p.energyUnit] ?? p.energyUnit;
    return '${p.weightUnit} · ${p.heightUnit} · $energy';
  }

  String get _goalsSummary {
    final p = _prefs;
    final calories = '${p.calorieGoal ?? kDefaultCalorieGoal} kcal';
    final custom = p.nutrientGoals.length;
    if (custom == 0) return calories;
    return '$calories · $custom custom';
  }

  String get _focusSummary {
    final specs = resolveFocusSpecs(_prefs.focusNutrients);
    return specs.map((spec) => spec.label).join(' · ');
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You can sign back in anytime.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: LuminaHealthColors.error,
            ),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.onLogout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AppScaffold(
      safeArea: true,
      padding: EdgeInsets.zero,
      appBar: AppBar(title: const Text('Settings'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        children: [
          AppSection(
            title: 'Account',
            child: _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.person_outline,
                  title: 'Profile',
                  subtitle: _profileSummary,
                  onTap: _openProfile,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppSection(
            title: 'Preferences',
            child: _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.straighten,
                  title: 'Units',
                  subtitle: _unitsSummary,
                  onTap: _openUnits,
                ),
                _SettingsTile(
                  icon: Icons.flag_outlined,
                  title: 'Daily goals',
                  subtitle: _goalsSummary,
                  onTap: _openGoals,
                ),
                _SettingsTile(
                  icon: Icons.track_changes,
                  title: 'Focus nutrients',
                  subtitle: _focusSummary,
                  onTap: _openFocusNutrients,
                ),
              ],
            ),
          ),
          // Logout — destructive, kept well clear of the normal actions above
          // (HIG: separate dangerous actions from routine ones).
          const SizedBox(height: AppSpacing.xxl),
          Divider(color: scheme.outlineVariant),
          const SizedBox(height: AppSpacing.md),
          TextButton.icon(
            onPressed: _confirmLogout,
            icon: const Icon(Icons.logout),
            label: const Text('Log out'),
            style: TextButton.styleFrom(
              foregroundColor: LuminaHealthColors.error,
              minimumSize: const Size(0, 48),
              alignment: Alignment.centerLeft,
            ),
          ),
        ],
      ),
    );
  }
}

/// Groups settings rows into one rounded surface with hairline dividers, so a
/// section reads as a single tappable block (iOS Settings / Material list
/// grouping).
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: AppRadius.card,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              Divider(
                height: 1,
                thickness: 1,
                // Aligns the divider with the row text (icon + gap).
                indent: AppSpacing.lg + 40 + AppSpacing.md,
                color: scheme.outlineVariant,
              ),
          ],
        ],
      ),
    );
  }
}

/// One navigation row: leading icon, title, current-value summary and a
/// chevron signalling a nested page.
class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(icon, size: 22, color: scheme.primary),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
