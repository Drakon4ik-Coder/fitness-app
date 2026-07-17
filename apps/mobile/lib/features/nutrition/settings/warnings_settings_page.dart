import 'package:flutter/material.dart';

import '../../../ui_components/ui_components.dart';
import '../../../ui_system/tokens.dart';
import '../data/api_exceptions.dart';
import '../data/nutrient_catalog.dart';
import '../data/preferences_api_service.dart';
import '../data/user_preferences.dart';
import 'settings_action_bar.dart';
import 'unsaved_changes_scope.dart';

/// Nested settings page for the opt-in over-goal warnings (KAN-38). By default
/// only the calorie ring warns; each nutrient picked here turns its over-goal
/// state amber across the today tiles, the nutrients page, and the meal/amount
/// sheets. The catalog's cautionary nutrients (sugars, sodium, …) are offered
/// as a one-tap suggestion but never pre-enabled — which overages deserve a
/// nag is a personal-goal question.
///
/// Pops with the server's updated [UserPreferences] snapshot when a save
/// succeeds.
class WarningsSettingsPage extends StatefulWidget {
  const WarningsSettingsPage({
    super.key,
    required this.preferencesApi,
    required this.initialPreferences,
  });

  final PreferencesApiService preferencesApi;
  final UserPreferences initialPreferences;

  @override
  State<WarningsSettingsPage> createState() => _WarningsSettingsPageState();
}

class _WarningsSettingsPageState extends State<WarningsSettingsPage> {
  late final Set<String> _selected;
  late final Set<String> _initialSelection;

  bool _saving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.initialPreferences.warnNutrients};
    _initialSelection = {..._selected};
  }

  bool get _dirty =>
      _selected.length != _initialSelection.length ||
      !_selected.containsAll(_initialSelection);

  void _toggle(String key) {
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  void _applySuggested() {
    setState(() => _selected.addAll(kSuggestedWarnNutrients));
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    try {
      // Persist in catalog order so the stored list is stable across edits.
      final updated = await widget.preferencesApi.update(
        warnNutrients: [
          for (final spec in kNutrientCatalog)
            if (_selected.contains(spec.key)) spec.key,
        ],
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Warnings saved')));
      Navigator.of(context).pop(updated);
    } on ApiException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final suggested = kSuggestedWarnNutrients;
    final hasAllSuggested = _selected.containsAll(suggested);

    return UnsavedChangesScope(
      dirty: _dirty,
      child: AppScaffold(
        safeArea: true,
        padding: EdgeInsets.zero,
        appBar: AppBar(
          title: const Text('Over-goal warnings'),
          centerTitle: false,
        ),
        bottomNavigationBar: SettingsActionBar(
          child: AppPrimaryButton(
            onPressed: _saving ? null : _save,
            isLoading: _saving,
            child: const Text('Save changes'),
          ),
        ),
        body: ListView(
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
            Text(
              'Calories always warn when you go over budget. Pick any other '
              'nutrients you want flagged when they exceed their daily goal — '
              'everything else stays informational.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('warnUseSuggested'),
                onPressed: hasAllSuggested ? null : _applySuggested,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Use suggested (sugars, sodium, …)'),
              ),
            ),
            for (final group in NutrientGroup.values) ...[
              const SizedBox(height: AppSpacing.md),
              Text(group.label, style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final spec in kNutrientCatalog)
                    if (spec.group == group)
                      FilterChip(
                        key: Key('warnChoice_${spec.key}'),
                        label: Text(spec.label),
                        selected: _selected.contains(spec.key),
                        onSelected: (_) => _toggle(spec.key),
                      ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
