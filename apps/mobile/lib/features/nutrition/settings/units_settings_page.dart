import 'package:flutter/material.dart';

import '../../../ui_components/ui_components.dart';
import '../../../ui_system/tokens.dart';
import '../data/api_exceptions.dart';
import '../data/preferences_api_service.dart';
import '../data/user_preferences.dart';
import 'unsaved_changes_scope.dart';

/// Nested settings page for measurement units. Saves only the unit fields
/// (the API PATCH is partial) and pops with the server's updated
/// [UserPreferences] snapshot.
class UnitsSettingsPage extends StatefulWidget {
  const UnitsSettingsPage({
    super.key,
    required this.preferencesApi,
    required this.initialPreferences,
  });

  final PreferencesApiService preferencesApi;
  final UserPreferences initialPreferences;

  @override
  State<UnitsSettingsPage> createState() => _UnitsSettingsPageState();
}

class _UnitsSettingsPageState extends State<UnitsSettingsPage> {
  late String _weightUnit;
  late String _heightUnit;
  late String _energyUnit;

  bool _saving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _weightUnit = widget.initialPreferences.weightUnit;
    _heightUnit = widget.initialPreferences.heightUnit;
    _energyUnit = widget.initialPreferences.energyUnit;
  }

  bool get _dirty =>
      _weightUnit != widget.initialPreferences.weightUnit ||
      _heightUnit != widget.initialPreferences.heightUnit ||
      _energyUnit != widget.initialPreferences.energyUnit;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    try {
      final updated = await widget.preferencesApi.update(
        weightUnit: _weightUnit,
        heightUnit: _heightUnit,
        energyUnit: _energyUnit,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Units saved')));
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
        appBar: AppBar(title: const Text('Units'), centerTitle: false),
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
              'Choose how measurements are shown across the app.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
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
            const SizedBox(height: AppSpacing.xl),
            AppPrimaryButton(
              onPressed: _saving ? null : _save,
              isLoading: _saving,
              child: const Text('Save changes'),
            ),
          ],
        ),
      ),
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
              ButtonSegment<String>(value: entry.key, label: Text(entry.value)),
          ],
          selected: {value},
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
      ],
    );
  }
}
