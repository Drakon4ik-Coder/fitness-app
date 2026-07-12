import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui_components/ui_components.dart';
import '../../ui_system/lumina_health_theme.dart';
import '../../ui_system/tokens.dart';
import 'data/food_models.dart';
import 'data/nutrient_catalog.dart';
import 'settings/unsaved_changes_scope.dart';

/// Client-generated id for a new custom food. Unique per (source='custom',
/// external_id) on the backend; timestamp + random suffix keeps collisions
/// out of reach without a uuid dependency.
String newCustomFoodId({Random? random}) {
  final rng = random ?? Random();
  final suffix = rng.nextInt(0x7FFFFFFF).toRadixString(16);
  return 'cf-${DateTime.now().microsecondsSinceEpoch}-$suffix';
}

/// Relative kcal-vs-macros disagreement above which the Atwater hint shows.
const double kAtwaterHintThreshold = 0.15;

/// Outcome of [CustomFoodPage]: a saved food, or a request to delete the one
/// being edited (mirrors the amount sheet's AmountResult pattern).
class CustomFoodResult {
  const CustomFoodResult._({this.item, this.deleted = false});

  factory CustomFoodResult.saved(FoodItem item) =>
      CustomFoodResult._(item: item);
  factory CustomFoodResult.deleted() => const CustomFoodResult._(deleted: true);

  final FoodItem? item;
  final bool deleted;
}

/// Create/edit form for a user's own food. Pure UI: collects the values and
/// pops a [CustomFoodResult] — persistence and backend sync stay with the
/// caller. Micros are written as OFF-format `nutriments_json`
/// (`<offKey>_100g` + `<offKey>_unit`), so the breakdown view, focus pills,
/// and amount sheet work on custom foods unchanged.
class CustomFoodPage extends StatefulWidget {
  const CustomFoodPage({super.key, this.initial, this.overrideOf});

  /// Existing custom food to edit; null creates a new one.
  final FoodItem? initial;

  /// Fork-on-edit (KAN-31): the global item whose nutrition is being
  /// corrected. The form prefills from it and saves a *new* custom food that
  /// shadows it for this user — the global item stays untouched for everyone
  /// else. Ignored when [initial] is set (the fork already exists).
  final FoodItem? overrideOf;

  @override
  State<CustomFoodPage> createState() => _CustomFoodPageState();
}

class _CustomFoodPageState extends State<CustomFoodPage> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _brandController;
  late final TextEditingController _servingController;
  late final TextEditingController _kcalController;

  /// One controller per catalog nutrient, keyed by [NutrientSpec.key]. The
  /// macro trio renders in the main section, the rest in grouped disclosures.
  late final Map<String, TextEditingController> _nutrients;

  /// Snapshot of every controller's initial text, for dirty tracking.
  late final Map<TextEditingController, String> _baseline;

  static const Set<String> _mainMacroKeys = {'protein', 'carbs', 'fat'};

  /// The item the form fields start from: the food being edited, or the
  /// global item being forked into an override.
  FoodItem? get _template => widget.initial ?? widget.overrideOf;

  bool get _isOverride =>
      widget.overrideOf != null || (widget.initial?.isOverride ?? false);

  @override
  void initState() {
    super.initState();
    final template = _template;
    _nameController = TextEditingController(text: template?.name ?? '');
    _brandController = TextEditingController(text: template?.brands ?? '');
    _servingController = TextEditingController(
      text: _numberText(template?.servingSizeG),
    );
    _kcalController = TextEditingController(
      text: _numberText(template?.kcal100g),
    );
    _nutrients = {
      for (final spec in kNutrientCatalog)
        spec.key: TextEditingController(
          text: template == null
              ? ''
              : _numberText(nutrientPer100gForItem(spec, template)),
        ),
    };
    _baseline = {
      for (final controller in _allControllers) controller: controller.text,
    };
    for (final controller in _allControllers) {
      controller.addListener(_onChanged);
    }
  }

  Iterable<TextEditingController> get _allControllers => [
    _nameController,
    _brandController,
    _servingController,
    _kcalController,
    ..._nutrients.values,
  ];

  @override
  void dispose() {
    for (final controller in _allControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  // Rebuild on any edit: drives the dirty flag and the live Atwater hint.
  void _onChanged() => setState(() {});

  bool get _dirty => _allControllers.any((c) => c.text != _baseline[c]);

  static String _numberText(double? value) {
    if (value == null) return '';
    final rounded = double.parse(value.toStringAsFixed(2));
    return rounded == rounded.roundToDouble()
        ? rounded.round().toString()
        : rounded.toString();
  }

  double? _valueOf(TextEditingController controller) {
    final text = controller.text.trim().replaceAll(',', '.');
    if (text.isEmpty) return null;
    final parsed = double.tryParse(text);
    return (parsed == null || parsed < 0) ? null : parsed;
  }

  /// Expected kcal from the entered macros (Atwater 4/4/9), or null while any
  /// of the four fields is missing.
  double? get _atwaterExpectedKcal {
    final kcal = _valueOf(_kcalController);
    final protein = _valueOf(_nutrients['protein']!);
    final carbs = _valueOf(_nutrients['carbs']!);
    final fat = _valueOf(_nutrients['fat']!);
    if (kcal == null || protein == null || carbs == null || fat == null) {
      return null;
    }
    final expected = 4 * protein + 4 * carbs + 9 * fat;
    final denom = max(kcal, 1.0);
    return (expected - kcal).abs() / denom > kAtwaterHintThreshold
        ? expected
        : null;
  }

  String? _validateNumber(
    String? raw, {
    required double maxValue,
    bool required = false,
  }) {
    final text = (raw ?? '').trim().replaceAll(',', '.');
    if (text.isEmpty) {
      return required ? 'Required' : null;
    }
    final value = double.tryParse(text);
    if (value == null || value < 0) return 'Enter a number';
    if (value > maxValue) return 'At most ${_numberText(maxValue)}';
    return null;
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();

    final kcal = _valueOf(_kcalController)!;
    final nutriments = <String, dynamic>{
      'energy-kcal_100g': kcal,
      'energy-kcal_unit': 'kcal',
    };
    for (final spec in kNutrientCatalog) {
      final value = _valueOf(_nutrients[spec.key]!);
      if (value == null) continue;
      nutriments['${spec.offKey}_100g'] = value;
      nutriments['${spec.offKey}_unit'] = spec.unit;
    }

    final initial = widget.initial;
    final item = FoodItem(
      localId: initial?.localId,
      backendId: initial?.backendId,
      source: customSource,
      externalId: initial?.externalId ?? newCustomFoodId(),
      barcode: null,
      overridesBackendId:
          initial?.overridesBackendId ?? widget.overrideOf?.backendId,
      overridesBarcode: initial?.overridesBarcode ?? widget.overrideOf?.barcode,
      name: _nameController.text.trim(),
      brands: _brandController.text.trim(),
      kcal100g: kcal,
      proteinG100g: _valueOf(_nutrients['protein']!),
      carbsG100g: _valueOf(_nutrients['carbs']!),
      fatG100g: _valueOf(_nutrients['fat']!),
      sugarsG100g: _valueOf(_nutrients['sugars']!),
      fiberG100g: _valueOf(_nutrients['fiber']!),
      saltG100g: _valueOf(_nutrients['salt']!),
      servingSizeG: _valueOf(_servingController),
      rawSourceJson: '{}',
      nutrimentsJson: nutriments,
      lastUsedAt: initial?.lastUsedAt,
      isFavorite: initial?.isFavorite ?? false,
    );
    Navigator.of(context).pop(CustomFoodResult.saved(item));
  }

  Future<void> _confirmDelete() async {
    // For an override, deletion means reverting to the original values.
    final isOverride = _isOverride;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isOverride ? 'Revert to the original?' : 'Delete this food?',
        ),
        content: Text(
          isOverride
              ? 'Your corrected values are removed and the catalog item '
                    'comes back. Logged meals keep their history.'
              : 'It disappears from search, but meals you already logged '
                    'with it keep their history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              isOverride ? 'Revert' : 'Delete',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.of(context).pop(CustomFoodResult.deleted());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final atwaterExpected = _atwaterExpectedKcal;

    return UnsavedChangesScope(
      dirty: _dirty,
      child: AppScaffold(
        safeArea: true,
        padding: EdgeInsets.zero,
        appBar: AppBar(
          title: Text(
            _isOverride
                ? 'Edit nutrition'
                : widget.initial == null
                ? 'Create food'
                : 'Edit food',
          ),
          centerTitle: false,
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
              if (_isOverride) ...[
                InlineBanner(
                  message:
                      'Your personal copy — only you see these '
                      'changes. The catalog item stays as-is for others.',
                  tone: InlineBannerTone.info,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              AppFormField(
                controller: _nameController,
                label: 'Name',
                textInputAction: TextInputAction.next,
                validator: (raw) =>
                    (raw ?? '').trim().isEmpty ? 'Enter a name' : null,
                bottomSpacing: AppSpacing.md,
              ),
              AppFormField(
                controller: _brandController,
                label: 'Brand (optional)',
                textInputAction: TextInputAction.next,
                bottomSpacing: AppSpacing.md,
              ),
              _numberField(
                controller: _servingController,
                label: 'Serving size (optional)',
                unit: 'g',
                maxValue: 5000,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'NUTRITION PER 100 G',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _numberField(
                controller: _kcalController,
                label: 'Calories',
                unit: 'kcal',
                maxValue: 900,
                required: true,
              ),
              if (atwaterExpected != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: LuminaHealthColors.warning,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        'Macros suggest ~${atwaterExpected.round()} kcal — '
                        'double-check the label.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: LuminaHealthColors.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              for (final key in _mainMacroKeys) ...[
                _specField(_specByKey(key), required: false),
                const SizedBox(height: AppSpacing.md),
              ],
              _MoreNutrientsSection(
                buildField: (spec) => _specField(spec, required: false),
              ),
              const SizedBox(height: AppSpacing.xl),
              AppPrimaryButton(
                onPressed: _save,
                child: Text(
                  widget.initial == null && !_isOverride
                      ? 'Create food'
                      : 'Save changes',
                ),
              ),
              if (widget.initial != null) ...[
                const SizedBox(height: AppSpacing.xs),
                TextButton(
                  onPressed: _confirmDelete,
                  child: Text(
                    _isOverride ? 'Revert to original' : 'Delete food',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.error,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  NutrientSpec _specByKey(String key) =>
      kNutrientCatalog.firstWhere((spec) => spec.key == key);

  Widget _specField(NutrientSpec spec, {required bool required}) {
    // Gram-denominated nutrients are physically capped by the 100 g basis;
    // mg/µg micros get a generous cap that still rejects unit mix-ups.
    final maxValue = spec.unit == 'g' ? 100.0 : 100000.0;
    return _numberField(
      controller: _nutrients[spec.key]!,
      label: spec.label,
      unit: spec.unit,
      maxValue: maxValue,
      required: required,
    );
  }

  Widget _numberField({
    required TextEditingController controller,
    required String label,
    required String unit,
    required double maxValue,
    bool required = false,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textInputAction: TextInputAction.next,
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
      decoration: InputDecoration(labelText: label, suffixText: unit),
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (raw) =>
          _validateNumber(raw, maxValue: maxValue, required: required),
    );
  }
}

/// Collapsible per-group sections for everything beyond the macro trio, so
/// the default form stays a quick five-field affair.
class _MoreNutrientsSection extends StatelessWidget {
  const _MoreNutrientsSection({required this.buildField});

  final Widget Function(NutrientSpec spec) buildField;

  static const Set<String> _mainMacroKeys = {'protein', 'carbs', 'fat'};

  @override
  Widget build(BuildContext context) {
    final groups = <NutrientGroup, List<NutrientSpec>>{};
    for (final spec in kNutrientCatalog) {
      if (_mainMacroKeys.contains(spec.key)) continue;
      groups.putIfAbsent(spec.group, () => []).add(spec);
    }

    return Column(
      children: [
        for (final entry in groups.entries)
          ExpansionTile(
            title: Text(
              entry.key == NutrientGroup.macros
                  ? 'More macros'
                  : entry.key.label,
            ),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: AppSpacing.md),
            children: [
              for (final spec in entry.value) ...[
                buildField(spec),
                const SizedBox(height: AppSpacing.md),
              ],
            ],
          ),
      ],
    );
  }
}
