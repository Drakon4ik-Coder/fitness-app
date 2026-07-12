import 'package:flutter/material.dart';

import '../../../ui_components/ui_components.dart';
import '../../../ui_system/tokens.dart';
import '../data/api_exceptions.dart';
import '../data/nutrient_catalog.dart';
import '../data/preferences_api_service.dart';
import '../data/user_preferences.dart';
import 'unsaved_changes_scope.dart';

/// Nested settings page for picking which 1-4 nutrients the today page
/// highlights (the "focus" card under the calorie ring). Tap order is display
/// order; the "Shown on Today" row makes that order visible and lets a pick be
/// removed directly.
///
/// Pops with the server's updated [UserPreferences] snapshot when a save
/// succeeds.
class FocusNutrientsSettingsPage extends StatefulWidget {
  const FocusNutrientsSettingsPage({
    super.key,
    required this.preferencesApi,
    required this.initialPreferences,
  });

  final PreferencesApiService preferencesApi;
  final UserPreferences initialPreferences;

  @override
  State<FocusNutrientsSettingsPage> createState() =>
      _FocusNutrientsSettingsPageState();
}

class _FocusNutrientsSettingsPageState
    extends State<FocusNutrientsSettingsPage> {
  /// Catalog keys in display order. Never empty on open (defaults resolve to
  /// the protein/carbs/fat trio) but the user may clear it down to zero while
  /// editing — Save is disabled until at least one is picked again.
  late final List<String> _selected;
  late final List<String> _initialSelection;

  bool _saving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _selected = [
      for (final spec in resolveFocusSpecs(
        widget.initialPreferences.focusNutrients,
      ))
        spec.key,
    ];
    _initialSelection = List.of(_selected);
  }

  bool get _dirty {
    if (_selected.length != _initialSelection.length) return true;
    for (var i = 0; i < _selected.length; i++) {
      if (_selected[i] != _initialSelection[i]) return true;
    }
    return false;
  }

  bool get _atLimit => _selected.length >= kMaxFocusNutrients;

  void _toggle(String key) {
    setState(() {
      if (_selected.contains(key)) {
        _selected.remove(key);
      } else if (!_atLimit) {
        _selected.add(key);
      }
    });
  }

  Future<void> _save() async {
    if (_selected.isEmpty) return;
    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    try {
      final updated = await widget.preferencesApi.update(
        focusNutrients: List.of(_selected),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Focus nutrients saved')));
      Navigator.of(context).pop(updated);
    } on ApiException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  NutrientSpec _spec(String key) =>
      kNutrientCatalog.firstWhere((spec) => spec.key == key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return UnsavedChangesScope(
      dirty: _dirty,
      child: AppScaffold(
        safeArea: true,
        padding: EdgeInsets.zero,
        appBar: AppBar(
          title: const Text('Focus nutrients'),
          centerTitle: false,
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
              'Pick up to $kMaxFocusNutrients nutrients to track at a glance '
              'on the Today page. They appear in the order you pick them.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Shown on Today', style: theme.textTheme.titleSmall),
                Text(
                  '${_selected.length} of $kMaxFocusNutrients',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_selected.isEmpty)
              Text(
                'Choose at least one nutrient below.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              )
            else
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final key in _selected)
                    InputChip(
                      key: Key('focusSelected_$key'),
                      label: Text(_spec(key).label),
                      onDeleted: () => _toggle(key),
                    ),
                ],
              ),
            const SizedBox(height: AppSpacing.md),
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
                        key: Key('focusChoice_${spec.key}'),
                        label: Text(spec.label),
                        selected: _selected.contains(spec.key),
                        // Adding is blocked at the limit; removing still works.
                        onSelected: _atLimit && !_selected.contains(spec.key)
                            ? null
                            : (_) => _toggle(spec.key),
                      ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
            AppPrimaryButton(
              onPressed: _saving || _selected.isEmpty ? null : _save,
              isLoading: _saving,
              child: const Text('Save changes'),
            ),
          ],
        ),
      ),
    );
  }
}
