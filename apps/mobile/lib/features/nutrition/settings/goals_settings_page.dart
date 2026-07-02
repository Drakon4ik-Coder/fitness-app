import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ui_components/ui_components.dart';
import '../../../ui_system/tokens.dart';
import '../data/api_exceptions.dart';
import '../data/nutrient_catalog.dart';
import '../data/preferences_api_service.dart';
import '../data/user_preferences.dart';
import '../widgets/nutrient_breakdown_view.dart' show formatNutrientValue;
import 'unsaved_changes_scope.dart';

/// Nested settings page for the daily energy and per-nutrient goals. Goals
/// entered here are the single source of truth both the today page and the
/// full breakdown read, so the two never disagree (see [resolveCatalog]).
///
/// Pops with the server's updated [UserPreferences] snapshot when a save
/// succeeds.
class GoalsSettingsPage extends StatefulWidget {
  const GoalsSettingsPage({
    super.key,
    required this.preferencesApi,
    required this.initialPreferences,
  });

  final PreferencesApiService preferencesApi;
  final UserPreferences initialPreferences;

  @override
  State<GoalsSettingsPage> createState() => _GoalsSettingsPageState();
}

class _GoalsSettingsPageState extends State<GoalsSettingsPage> {
  final _formKey = GlobalKey<FormState>();

  final _calorieController = TextEditingController();
  // One controller per catalog nutrient, keyed by spec.key. Empty means "use the
  // recommended default"; a number is a personalized goal.
  final Map<String, TextEditingController> _goalControllers = {};

  late final String _initialCalorieText;
  late final Map<String, String> _initialGoalTexts;

  bool _saving = false;
  bool _dirty = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final prefs = widget.initialPreferences;
    _calorieController.text = (prefs.calorieGoal ?? kDefaultCalorieGoal)
        .toString();
    for (final spec in kNutrientCatalog) {
      final override = prefs.nutrientGoals[spec.key];
      _goalControllers[spec.key] = TextEditingController(
        text: override != null ? formatNutrientValue(override) : '',
      );
    }
    _initialCalorieText = _calorieController.text;
    _initialGoalTexts = {
      for (final entry in _goalControllers.entries)
        entry.key: entry.value.text,
    };
    _calorieController.addListener(_recomputeDirty);
    for (final controller in _goalControllers.values) {
      controller.addListener(_recomputeDirty);
    }
  }

  @override
  void dispose() {
    _calorieController.dispose();
    for (final controller in _goalControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _recomputeDirty() {
    final dirty =
        _calorieController.text != _initialCalorieText ||
        _goalControllers.entries.any(
          (entry) => entry.value.text != _initialGoalTexts[entry.key],
        );
    if (dirty != _dirty) setState(() => _dirty = dirty);
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
      final updated = await widget.preferencesApi.update(
        calorieGoal: int.tryParse(_calorieController.text.trim()),
        nutrientGoals: _collectGoals(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Goals saved')));
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

    return UnsavedChangesScope(
      dirty: _dirty,
      child: AppScaffold(
        safeArea: true,
        padding: EdgeInsets.zero,
        appBar: AppBar(
          title: const Text('Daily goals'),
          centerTitle: false,
          actions: [
            TextButton(
              onPressed: _saving ? null : _resetToRecommended,
              // The app theme makes TextButtons full-width (minimumSize
              // Size.fromHeight); as a non-flex row child that forces an
              // infinite width, so pin a content-sized minimum here.
              style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
              child: const Text('Reset'),
            ),
          ],
        ),
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
              const SizedBox(height: AppSpacing.xl),
              AppPrimaryButton(
                onPressed: _saving ? null : _save,
                isLoading: _saving,
                child: const Text('Save changes'),
              ),
            ],
          ),
        ),
      ),
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
        // Top inset keeps the first field's always-floating label (drawn ~half
        // its height above the outline) clear of the group title row.
        childrenPadding: const EdgeInsets.only(
          top: AppSpacing.md,
          bottom: AppSpacing.sm,
        ),
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
        // Keep the label floated so an empty field shows the recommended
        // default as its hint instead of hiding it behind the inline label.
        floatingLabelBehavior: FloatingLabelBehavior.always,
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
