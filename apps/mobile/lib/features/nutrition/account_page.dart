import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/auth_interceptor.dart';
import '../../core/auth_service.dart';
import '../../ui_components/ui_components.dart';
import '../../ui_system/lumina_health_theme.dart';
import '../../ui_system/tokens.dart';
import 'data/api_exceptions.dart';
import 'data/nutrient_catalog.dart';
import 'data/preferences_api_service.dart';
import 'data/user_preferences.dart';
import 'widgets/nutrient_breakdown_view.dart' show formatNutrientValue;

/// Where the user edits their goals and units, and signs out. Nutrient goals
/// entered here are the single source of truth both the today page and the full
/// breakdown read, so the two never disagree (see [resolveCatalog]).
///
/// Pops with the updated [UserPreferences] when a save succeeds, so the caller
/// can refresh without a round-trip.
class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    required this.accessToken,
    required this.preferencesApi,
    required this.onLogout,
    this.authInterceptor,
    this.authService,
    this.initialPreferences,
  });

  final String accessToken;
  final PreferencesApiService preferencesApi;
  final Future<void> Function() onLogout;
  final AuthInterceptor? authInterceptor;
  final AuthService? authService;

  /// The goals/units already loaded by the caller, shown immediately so the
  /// form isn't blank on open. Null when the caller hasn't loaded them yet.
  final UserPreferences? initialPreferences;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _formKey = GlobalKey<FormState>();
  late final AuthService _authService;

  final _displayNameController = TextEditingController();
  final _calorieController = TextEditingController();
  // One controller per catalog nutrient, keyed by spec.key. Empty means "use the
  // recommended default"; a number is a personalized goal.
  final Map<String, TextEditingController> _goalControllers = {};

  late String _weightUnit;
  late String _heightUnit;
  late String _energyUnit;

  String _email = '';
  bool _saving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? AuthService();
    final prefs = widget.initialPreferences ?? const UserPreferences();
    _weightUnit = prefs.weightUnit;
    _heightUnit = prefs.heightUnit;
    _energyUnit = prefs.energyUnit;
    _calorieController.text = (prefs.calorieGoal ?? kDefaultCalorieGoal)
        .toString();
    for (final spec in kNutrientCatalog) {
      final override = prefs.nutrientGoals[spec.key];
      _goalControllers[spec.key] = TextEditingController(
        text: override != null ? formatNutrientValue(override) : '',
      );
    }
    _loadAccount();
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _calorieController.dispose();
    for (final controller in _goalControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadAccount() async {
    final info = await _authService.fetchMe(accessToken: widget.accessToken);
    if (!mounted || info == null) return;
    setState(() {
      _email = info.email;
      if (_displayNameController.text.isEmpty) {
        _displayNameController.text = info.displayName;
      }
    });
  }

  /// Clears every goal field back to its recommended default. Nothing is saved
  /// until the user taps Save, so this is a non-destructive form reset.
  void _resetToRecommended() {
    setState(() {
      _calorieController.text = kDefaultCalorieGoal.toString();
      for (final controller in _goalControllers.values) {
        controller.clear();
      }
    });
  }

  /// Builds the sparse overrides map: only nutrients the user gave a value for.
  /// Empty fields fall back to the catalog default, so they're omitted.
  Map<String, double> _collectGoals() {
    final goals = <String, double>{};
    for (final spec in kNutrientCatalog) {
      final text = _goalControllers[spec.key]!.text.trim();
      if (text.isEmpty) continue;
      final value = double.tryParse(text);
      if (value != null && value > 0) goals[spec.key] = value;
    }
    return goals;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    try {
      final displayName = _displayNameController.text.trim();
      if (displayName.isNotEmpty) {
        await _authService.updateDisplayName(
          accessToken: widget.accessToken,
          displayName: displayName,
        );
      }
      final updated = await widget.preferencesApi.update(
        weightUnit: _weightUnit,
        heightUnit: _heightUnit,
        energyUnit: _energyUnit,
        calorieGoal: int.tryParse(_calorieController.text.trim()),
        nutrientGoals: _collectGoals(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Preferences saved')),
      );
      Navigator.of(context).pop(updated);
    } on ApiException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } on AuthException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AppScaffold(
      safeArea: true,
      padding: EdgeInsets.zero,
      appBar: AppBar(title: const Text('Account'), centerTitle: false),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.xxl,
          ),
          children: [
            if (_errorMessage != null) ...[
              InlineBanner(
                message: _errorMessage!,
                tone: InlineBannerTone.error,
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
            // Account
            AppSection(
              title: 'Account',
              child: Column(
                children: [
                  AppFormField(
                    controller: _displayNameController,
                    label: 'Display name',
                    textInputAction: TextInputAction.next,
                    bottomSpacing: AppSpacing.md,
                  ),
                  _ReadOnlyRow(label: 'Email', value: _email),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            // Units
            AppSection(
              title: 'Units',
              child: Column(
                children: [
                  _UnitRow(
                    label: 'Weight',
                    value: _weightUnit,
                    options: const {'kg': 'kg', 'lb': 'lb'},
                    onChanged: (v) => setState(() => _weightUnit = v),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _UnitRow(
                    label: 'Height',
                    value: _heightUnit,
                    options: const {'cm': 'cm', 'in': 'in'},
                    onChanged: (v) => setState(() => _heightUnit = v),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _UnitRow(
                    label: 'Energy',
                    value: _energyUnit,
                    options: const {'kcal': 'kcal', 'kj': 'kJ'},
                    onChanged: (v) => setState(() => _energyUnit = v),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            // Goals
            AppSection(
              title: 'Daily goals',
              trailing: TextButton(
                onPressed: _saving ? null : _resetToRecommended,
                // The app theme makes TextButtons full-width (minimumSize
                // Size.fromHeight); as a non-flex row child that forces an
                // infinite width, so pin a content-sized minimum here.
                style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                child: const Text('Reset'),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Leave a field blank to use the recommended default.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _GoalField(
                    controller: _calorieController,
                    label: 'Calories',
                    unit: 'kcal',
                    hint: '$kDefaultCalorieGoal',
                    integer: true,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  for (final group in NutrientGroup.values)
                    _GoalGroup(
                      title: group.label,
                      initiallyExpanded: group == NutrientGroup.macros,
                      specs: [
                        for (final spec in kNutrientCatalog)
                          if (spec.group == group) spec,
                      ],
                      controllers: _goalControllers,
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            AppPrimaryButton(
              onPressed: _saving ? null : _save,
              isLoading: _saving,
              child: const Text('Save changes'),
            ),
            // Logout — destructive, kept well clear of the normal actions above
            // (HIG: separate dangerous actions from routine ones).
            const SizedBox(height: AppSpacing.xxl),
            Divider(color: scheme.outlineVariant),
            const SizedBox(height: AppSpacing.md),
            TextButton.icon(
              onPressed: _saving ? null : _confirmLogout,
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
      ),
    );
  }
}

class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        Flexible(
          child: Text(
            value.isEmpty ? '—' : value,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

class _UnitRow extends StatelessWidget {
  const _UnitRow({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;

  /// Stored value → shown label (e.g. `kj` → `kJ`).
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: theme.textTheme.bodyMedium),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            for (final entry in options.entries)
              ButtonSegment<String>(
                value: entry.key,
                label: Text(entry.value),
              ),
          ],
          selected: {value},
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
      ],
    );
  }
}

class _GoalGroup extends StatelessWidget {
  const _GoalGroup({
    required this.title,
    required this.specs,
    required this.controllers,
    this.initiallyExpanded = false,
  });

  final String title;
  final List<NutrientSpec> specs;
  final Map<String, TextEditingController> controllers;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      // ExpansionTile draws its own dividers; drop them so the section reads as
      // one grouped block within the card-free form.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: Text(title, style: theme.textTheme.titleSmall),
        initiallyExpanded: initiallyExpanded,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
        children: [
          for (final spec in specs)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: _GoalField(
                controller: controllers[spec.key]!,
                label: spec.label,
                unit: spec.unit,
                hint: formatNutrientValue(spec.dailyTarget),
              ),
            ),
        ],
      ),
    );
  }
}

class _GoalField extends StatelessWidget {
  const _GoalField({
    required this.controller,
    required this.label,
    required this.unit,
    required this.hint,
    this.integer = false,
  });

  final TextEditingController controller;
  final String label;
  final String unit;

  /// The recommended default, shown as placeholder text.
  final String hint;
  final bool integer;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.numberWithOptions(decimal: !integer),
      inputFormatters: [
        FilteringTextInputFormatter.allow(
          integer ? RegExp(r'[0-9]') : RegExp(r'[0-9.]'),
        ),
      ],
      autovalidateMode: AutovalidateMode.onUserInteraction,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixText: unit,
      ),
      validator: (raw) {
        final text = (raw ?? '').trim();
        if (text.isEmpty) return null; // blank → recommended default
        final value = double.tryParse(text);
        if (value == null || value <= 0) return 'Enter a number above 0';
        return null;
      },
    );
  }
}
