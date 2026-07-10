import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ui_system/lumina_health_theme.dart';
import '../../../ui_system/tokens.dart';
import '../data/food_models.dart';
import '../data/nutrient_catalog.dart';
import 'nutrient_breakdown_view.dart';

/// Formats a number without a trailing `.0` and at most one decimal place.
String formatAmount(double value) {
  return value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1);
}

/// Pluralizes a piece/serving noun by count ("egg" -> "eggs" at 2).
String pluralize(String unit, double count) {
  final singular = (count - 1).abs() < 0.001;
  return singular ? unit : '${unit}s';
}

/// Human label for a logged amount. Reads in pieces when the food is counted in
/// pieces ("2 eggs (105 g)"), else in servings ("1 serving (215 g)"), else in
/// plain grams ("150 g"). Grams always shown in parentheses for transparency.
String describeAmount(double grams, FoodItem item) {
  final piece = item.gramsPerPiece;
  if (piece != null && piece > 0 && item.pieceUnit != null) {
    final count = grams / piece;
    final unit = pluralize(item.pieceUnit!, count);
    return '${formatAmount(count)} $unit (${formatAmount(grams)} g)';
  }
  // Cooked-basis foods (sold raw, label per cooked weight) read as the raw
  // weight the user actually put on the scale, with the cooked-equivalent
  // grams the nutrition scales by in parentheses.
  if (item.isCookedBasis) {
    final raw = grams / kCookedYieldFactor;
    return '${formatAmount(raw)} g raw (${formatAmount(grams)} g cooked)';
  }
  final serving = item.servingSizeG;
  if (serving != null && serving > 0) {
    final servings = grams / serving;
    final unit = pluralize('serving', servings);
    return '${formatAmount(servings)} $unit (${formatAmount(grams)} g)';
  }
  return '${formatAmount(grams)} g';
}

/// Rounded food thumbnail used in cart rows, the amount sheet header, and the
/// meal-details list. Reuses [FoodImage] for the URL/placeholder/error handling.
class FoodThumb extends StatelessWidget {
  const FoodThumb({super.key, required this.url, this.size = 44});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: SizedBox(
        width: size,
        height: size,
        child: FoodImage(url: url, cacheWidth: size.round()),
      ),
    );
  }
}

/// Fills a food card with its photo. Shows a neutral food placeholder when no
/// image URL is known, and — when an image URL exists but fails to load — a
/// tappable red reload button that evicts the cached failure and retries.
class FoodImage extends StatefulWidget {
  const FoodImage({super.key, required this.url, this.cacheWidth});

  final String? url;

  /// Decode-target width in *logical* pixels for small slots (list thumbs,
  /// the today page's 64px meal images). OFF photos arrive full-size, so
  /// without this the engine decodes megapixels for a thumbnail (KAN-60).
  /// Null decodes at native resolution — right for full-card images.
  final int? cacheWidth;

  @override
  State<FoodImage> createState() => _FoodImageState();
}

class _FoodImageState extends State<FoodImage> {
  // Bumped on each manual retry; folded into the Image key so a new element is
  // created and the network fetch is re-attempted.
  int _attempt = 0;

  Future<void> _retry() async {
    final url = widget.url;
    if (url != null && url.isNotEmpty) {
      await NetworkImage(url).evict();
    }
    if (mounted) setState(() => _attempt++);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = widget.url;
    if (url == null || url.isEmpty) {
      return _placeholder(scheme);
    }
    final logicalWidth = widget.cacheWidth;
    return Image.network(
      url,
      key: ValueKey('$url#$_attempt'),
      fit: BoxFit.cover,
      // Image.network's cacheWidth is in physical pixels; scale the logical
      // slot width by the device ratio so the thumb stays crisp.
      cacheWidth: logicalWidth == null
          ? null
          : (logicalWidth * MediaQuery.devicePixelRatioOf(context)).round(),
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : _placeholder(scheme),
      errorBuilder: (context, error, stackTrace) => _errorState(scheme),
    );
  }

  Widget _placeholder(ColorScheme scheme) {
    return Container(
      color: scheme.surfaceContainerHigh,
      child: Center(
        child: Icon(
          Icons.restaurant_menu,
          color: scheme.onSurfaceVariant,
          size: 32,
        ),
      ),
    );
  }

  Widget _errorState(ColorScheme scheme) {
    return Container(
      color: scheme.surfaceContainerHigh,
      child: Center(
        child: IconButton(
          onPressed: _retry,
          tooltip: 'Retry loading image',
          icon: const Icon(Icons.refresh),
          color: scheme.error,
          style: IconButton.styleFrom(
            backgroundColor: scheme.error.withValues(alpha: 0.12),
          ),
        ),
      ),
    );
  }
}

enum AmountUnit { pieces, servings, grams }

/// Icon for each meal slot. Lives in the widget layer (not on [MealType])
/// so the data layer stays free of Flutter imports.
IconData mealTypeIcon(MealType meal) => switch (meal) {
  MealType.breakfast => Icons.breakfast_dining,
  MealType.lunch => Icons.lunch_dining,
  MealType.dinner => Icons.dinner_dining,
  MealType.snacks => Icons.emoji_food_beverage,
};

/// Accent color for each meal slot (KAN-3), drawn from the theme's existing
/// four-accent set so no new literals enter feature code and contrast on dark
/// surfaces is already proven. The mapping follows the day: orange sunrise for
/// breakfast, the green brand midday for lunch, purple evening for dinner,
/// cyan for snacks. Color never carries the meaning alone — every surface
/// pairs it with the meal's [mealTypeIcon] and label.
Color mealTypeAccent(MealType meal) => switch (meal) {
  MealType.breakfast => LuminaHealthColors.tertiary,
  MealType.lunch => LuminaHealthColors.primary,
  MealType.dinner => LuminaHealthColors.secondary,
  MealType.snacks => LuminaHealthColors.quaternary,
};

/// The meal types an entry can be moved between, with their display label,
/// icon, and accent (matching the meal cards on the today page). Keyed by the
/// backend `meal_type` name.
final List<({String name, String label, IconData icon, Color color})>
kMealTypeOptions = [
  for (final meal in MealType.values)
    (
      name: meal.wireName,
      label: meal.label,
      icon: mealTypeIcon(meal),
      color: mealTypeAccent(meal),
    ),
];

/// Outcome of the amount bottom sheet: either a saved amount (with an optional
/// [mealType] change when editing) or a request to [removed] the item.
class AmountResult {
  const AmountResult._({this.grams, this.mealType, this.removed = false});

  factory AmountResult.save(double grams, {String? mealType}) =>
      AmountResult._(grams: grams, mealType: mealType);
  factory AmountResult.remove() => const AmountResult._(removed: true);

  final double? grams;

  /// The chosen `meal_type` name when editing (may equal the original — the
  /// caller diffs); null in add mode where the meal is picked elsewhere.
  final String? mealType;
  final bool removed;
}

/// Opens the amount editor as a modal bottom sheet and resolves with the user's
/// choice ([AmountResult]) or null if they dismissed it. When [initialMealType]
/// is given (editing a logged entry), a meal-type selector is shown so the entry
/// can be moved between meals.
Future<AmountResult?> showAmountSheet({
  required BuildContext context,
  required FoodItem item,
  required double initialGrams,
  required bool isEditing,
  String? initialMealType,
  List<NutrientSpec>? focusSpecs,
  Set<String> warnNutrients = const {},
  Future<FoodItem?> Function(FoodItem item)? onViewDetails,
}) {
  return showModalBottomSheet<AmountResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => AmountSheet(
      item: item,
      initialGrams: initialGrams,
      isEditing: isEditing,
      initialMealType: initialMealType,
      focusSpecs: focusSpecs,
      warnNutrients: warnNutrients,
      onViewDetails: onViewDetails,
    ),
  );
}

class AmountSheet extends StatefulWidget {
  const AmountSheet({
    super.key,
    required this.item,
    required this.initialGrams,
    required this.isEditing,
    this.initialMealType,
    this.focusSpecs,
    this.warnNutrients = const {},
    this.onViewDetails,
  });

  final FoodItem item;
  final double initialGrams;
  final bool isEditing;

  /// The entry's current `meal_type` when editing; enables the meal selector.
  final String? initialMealType;

  /// The user's focus nutrients (goal-resolved, in display order), shown as the
  /// live-preview pills. Null falls back to the default trio.
  final List<NutrientSpec>? focusSpecs;

  /// Catalog keys the user opted into over-goal warnings for (KAN-38),
  /// forwarded to the expandable nutrition-facts breakdown.
  final Set<String> warnNutrients;

  /// Opens the food detail page for the sheet's food (KAN-33), resolving with
  /// the updated item when it was edited there (null = unchanged). When set,
  /// the header (thumbnail + name) becomes tappable; when null the header is
  /// inert, so call sites without the detail-page services keep working.
  final Future<FoodItem?> Function(FoodItem item)? onViewDetails;

  @override
  State<AmountSheet> createState() => _AmountSheetState();
}

class _AmountSheetState extends State<AmountSheet> {
  // The food being amounted. Live: viewing details can replace it (an edit or
  // a fresh override), and the preview/breakdown recompute from the new values.
  late FoodItem _item = widget.item;
  late final TextEditingController _controller;
  late AmountUnit _unit;
  bool _showAllNutrients = false;
  // The selected meal type when editing; null in add mode (no selector shown).
  late String? _mealType = widget.initialMealType;
  // For cooked-basis foods: whether typed grams are the raw (uncooked)
  // weight, converted via [kCookedYieldFactor] into the cooked-equivalent
  // grams the label values scale by. Raw is the default — the product is
  // sold uncooked, so that's what the user's scale shows.
  late bool _rawWeight = _item.isCookedBasis;

  bool get _showMealSelector =>
      widget.isEditing && widget.initialMealType != null;

  double? get _serving {
    final serving = _item.servingSizeG;
    return (serving != null && serving > 0) ? serving : null;
  }

  double? get _piece {
    final piece = _item.gramsPerPiece;
    return (piece != null && piece > 0 && _item.pieceUnit != null)
        ? piece
        : null;
  }

  bool get _hasServing => _serving != null;
  bool get _hasPiece => _piece != null;

  String? get _imageUrl {
    final url = _item.imageUrl?.trim();
    return (url != null && url.isNotEmpty) ? url : null;
  }

  // A serving is only worth showing alongside pieces when it spans more than one
  // piece (e.g. serving = 2 eggs); otherwise the two units are identical.
  bool get _servingDiffersFromPiece =>
      _hasServing &&
      (!_hasPiece || (_serving! - _piece!).abs() / _serving! > 0.01);

  // Units offered in the toggle, in display order. Always ends with Grams.
  List<AmountUnit> get _units => [
    if (_hasPiece) AmountUnit.pieces,
    if (_servingDiffersFromPiece) AmountUnit.servings,
    AmountUnit.grams,
  ];

  // Grams represented by one of the given unit.
  double _gramsPerUnit(AmountUnit unit) {
    switch (unit) {
      case AmountUnit.pieces:
        return _piece!;
      case AmountUnit.servings:
        return _serving!;
      case AmountUnit.grams:
        // In raw mode for a cooked-basis food, one typed gram of raw weight
        // is only kCookedYieldFactor grams of the cooked weight that the
        // per-100g label values scale against.
        return _item.isCookedBasis && _rawWeight ? kCookedYieldFactor : 1;
    }
  }

  @override
  void initState() {
    super.initState();
    _unit = _hasPiece
        ? AmountUnit.pieces
        : _hasServing
        ? AmountUnit.servings
        : AmountUnit.grams;
    _controller = TextEditingController(
      text: formatAmount(_valueForGrams(widget.initialGrams)),
    );
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _valueForGrams(double grams) => grams / _gramsPerUnit(_unit);

  double? get _value {
    final value = double.tryParse(_controller.text.trim().replaceAll(',', '.'));
    if (value == null || value <= 0) return null;
    return value;
  }

  double? get _grams {
    final value = _value;
    if (value == null) return null;
    return value * _gramsPerUnit(_unit);
  }

  double get _step => _unit == AmountUnit.grams ? 10.0 : 1.0;

  List<double> get _presets =>
      _unit == AmountUnit.grams ? const [50, 100, 150, 200] : const [1, 2, 3];

  void _setText(double value) {
    _controller.text = formatAmount(value);
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
  }

  void _bump(int direction) {
    final current = _value ?? 0;
    var next = current + direction * _step;
    if (next < _step) next = _step;
    _setText(next);
  }

  void _setUnit(AmountUnit unit) {
    if (unit == _unit) return;
    final grams = _grams ?? widget.initialGrams;
    setState(() {
      _unit = unit;
      _setText(grams / _gramsPerUnit(unit));
    });
  }

  void _setRawWeight(bool raw) {
    if (raw == _rawWeight) return;
    final grams = _grams ?? widget.initialGrams;
    setState(() {
      _rawWeight = raw;
      _setText(grams / _gramsPerUnit(_unit));
    });
  }

  void _submit() {
    final grams = _grams;
    if (grams == null) return;
    Navigator.of(context).pop(
      AmountResult.save(grams, mealType: _showMealSelector ? _mealType : null),
    );
  }

  Future<void> _openDetails() async {
    final updated = await widget.onViewDetails!(_item);
    if (updated != null && mounted) {
      setState(() => _item = updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final grams = _grams;
    final factor = (grams ?? 0) / 100.0;

    final kcal = ((_item.kcal100g ?? 0) * factor).round();
    // The user's focus nutrients as preview pills, matching the today page's
    // card (same nutrients, same slot colors). Null when the food carries no
    // data for one — the pill shows a dash rather than a misleading 0.
    final focusSpecs = widget.focusSpecs ?? resolveFocusSpecs(null);
    final focusAmounts = [
      for (final spec in focusSpecs)
        () {
          final per100 = nutrientPer100gForItem(spec, _item);
          return per100 == null ? null : per100 * factor;
        }(),
    ];

    // Full breakdown scaled to the current amount, for the "check the nutrition
    // before adding" disclosure. Only offered when the food actually carries
    // detail beyond the macro pills already shown.
    final nutrientTotals = grams == null
        ? const <NutrientTotal>[]
        : nutrientTotalsForItem(_item, grams);
    final hasNutrientDetail = nutrientTotals.any((t) => t.hasData);

    final unitLabel = _unitNoun(_value ?? 0);
    final conversion = _conversionLabel(grams);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg * 1.5),
          ),
        ),
        // Cap the height and scroll so revealing the full nutrient breakdown
        // never pushes the primary action off-screen.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: AppSpacing.md),
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              // Header: thumbnail + name. With [onViewDetails] wired it opens
              // the food detail page (full nutrition facts + visible edit),
              // signalled by the trailing chevron.
              Builder(
                builder: (context) {
                  final canViewDetails = widget.onViewDetails != null;
                  final header = Row(
                    children: [
                      FoodThumb(url: _imageUrl, size: 48),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _item.name,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _item.kcal100g == null
                                  ? 'Calories per 100g unavailable'
                                  : '${_item.kcal100g!.round()} kcal per '
                                        '100g${_item.isCookedBasis ? ' cooked' : ''}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (canViewDetails)
                        Icon(
                          Icons.chevron_right,
                          color: scheme.onSurfaceVariant,
                        ),
                    ],
                  );
                  if (!canViewDetails) return header;
                  return Semantics(
                    button: true,
                    label: '${_item.name}, view food details',
                    child: InkWell(
                      onTap: _openDetails,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.xs,
                        ),
                        child: header,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.lg),

              // Meal selector (editing only) — lets the user move a logged entry
              // to a different meal, e.g. fixing a mis-suggested meal type.
              if (_showMealSelector) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'MEAL',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: kMealTypeOptions.map((option) {
                    final selected = option.name == _mealType;
                    return ChoiceChip(
                      label: Text(option.label),
                      avatar: Icon(
                        option.icon,
                        size: 18,
                        color: selected ? scheme.onPrimary : option.color,
                      ),
                      selected: selected,
                      showCheckmark: false,
                      onSelected: (_) =>
                          setState(() => _mealType = option.name),
                      backgroundColor: scheme.surfaceContainerLow,
                      selectedColor: scheme.primary,
                      labelStyle: theme.textTheme.labelLarge?.copyWith(
                        color: selected ? scheme.onPrimary : scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                      side: BorderSide.none,
                    );
                  }).toList(),
                ),
                const SizedBox(height: AppSpacing.lg),
              ],

              // Unit toggle (shown when more than one unit is available, e.g. a
              // food counted in pieces or with a known serving size).
              if (_units.length > 1) ...[
                SegmentedButton<AmountUnit>(
                  segments: _units
                      .map(
                        (u) => ButtonSegment(
                          value: u,
                          label: Text(_segmentLabel(u)),
                        ),
                      )
                      .toList(),
                  selected: {_unit},
                  onSelectionChanged: (s) => _setUnit(s.first),
                  showSelectedIcon: false,
                  style: ButtonStyle(visualDensity: VisualDensity.compact),
                ),
                const SizedBox(height: AppSpacing.lg),
              ],

              // Raw/cooked weight toggle for foods sold raw whose label states
              // nutrition per cooked weight — lets the user type what their
              // scale shows and have the water loss accounted for.
              if (_item.isCookedBasis && _unit == AmountUnit.grams) ...[
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Raw weight')),
                    ButtonSegment(value: false, label: Text('Cooked weight')),
                  ],
                  selected: {_rawWeight},
                  onSelectionChanged: (s) => _setRawWeight(s.first),
                  showSelectedIcon: false,
                  style: ButtonStyle(visualDensity: VisualDensity.compact),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'This label gives nutrition per 100 g cooked. Raw weights '
                  'are converted for you (~25% cooking loss).',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
              ],

              // Stepper: −  [ number ]  +
              Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: () => _bump(-1),
                    iconSize: 24,
                    tooltip: 'Decrease',
                    icon: const Icon(Icons.remove),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textAlign: TextAlign.center,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      // Same digits-and-separators filter as the custom-food
                      // number fields — the numeric keyboard alone doesn't
                      // block letters from hardware keyboards or paste.
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                      ],
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: () => _bump(1),
                    iconSize: 24,
                    tooltip: 'Increase',
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              // Invalid input (empty, zero, or a malformed number) disables
              // the submit button; say why in the unit label's slot instead of
              // leaving a dead button unexplained (KAN-61).
              Center(
                child: grams == null
                    ? Text(
                        'Enter an amount above 0',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : Text(
                        conversion == null
                            ? unitLabel
                            : '$unitLabel  •  $conversion',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
              ),
              const SizedBox(height: AppSpacing.lg),

              // Quick presets
              Wrap(
                alignment: WrapAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: _presets.map((preset) {
                  final selected = (_value ?? -1) == preset;
                  final label = _unit == AmountUnit.grams
                      ? '${formatAmount(preset)}g'
                      : '${formatAmount(preset)}×';
                  return ChoiceChip(
                    label: Text(label),
                    selected: selected,
                    showCheckmark: false,
                    onSelected: (_) => _setText(preset),
                    backgroundColor: scheme.surfaceContainerLow,
                    selectedColor: scheme.primary,
                    labelStyle: theme.textTheme.labelLarge?.copyWith(
                      color: selected ? scheme.onPrimary : scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                    side: BorderSide.none,
                  );
                }).toList(),
              ),
              const SizedBox(height: AppSpacing.lg),

              // Live preview
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                // Wrap instead of a spaceBetween Row so large system text
                // scales flow the pills under the kcal figure rather than
                // overflowing the sheet (KAN-40). One run renders identically.
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppSpacing.md,
                  runSpacing: AppSpacing.sm,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          '$kcal',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'kcal',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.xs,
                      children: [
                        for (var i = 0; i < focusSpecs.length; i++)
                          MacroPill(
                            label: focusSpecs[i].pillLabel,
                            value: focusAmounts[i],
                            unit: focusSpecs[i].unit,
                            color:
                                LuminaHealthColors.focusAccents[i %
                                    LuminaHealthColors.focusAccents.length],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              // Full nutrient breakdown, revealed on demand so the user can check
              // vitamins/minerals before committing without cluttering the sheet.
              if (hasNutrientDetail) ...[
                const SizedBox(height: AppSpacing.sm),
                InkWell(
                  onTap: () =>
                      setState(() => _showAllNutrients = !_showAllNutrients),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.sm,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _showAllNutrients
                              ? 'Hide nutrition facts'
                              : 'View nutrition facts',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        AnimatedRotation(
                          turns: _showAllNutrients ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.expand_more,
                            size: 18,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.topCenter,
                  child: _showAllNutrients
                      ? NutrientBreakdownView(
                          totals: nutrientTotals,
                          showEmptyRows: false,
                          warnNutrients: widget.warnNutrients,
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),

              // Primary action
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: grams == null ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  child: Text(
                    widget.isEditing ? 'Save changes' : 'Add to meal',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
              ),
              if (widget.isEditing) ...[
                const SizedBox(height: AppSpacing.xs),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(AmountResult.remove()),
                  child: Text(
                    'Remove from meal',
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

  // Capitalized plural label for a unit toggle segment ("Eggs", "Servings",
  // "Grams").
  String _segmentLabel(AmountUnit unit) {
    switch (unit) {
      case AmountUnit.pieces:
        final noun = '${_item.pieceUnit!}s';
        return noun[0].toUpperCase() + noun.substring(1);
      case AmountUnit.servings:
        return 'Servings';
      case AmountUnit.grams:
        return 'Grams';
    }
  }

  // The noun shown under the stepper, agreeing in number with [count].
  String _unitNoun(double count) {
    switch (_unit) {
      case AmountUnit.pieces:
        return pluralize(_item.pieceUnit!, count);
      case AmountUnit.servings:
        return pluralize('serving', count);
      case AmountUnit.grams:
        if (_item.isCookedBasis) {
          return _rawWeight ? 'grams raw' : 'grams cooked';
        }
        return 'grams';
    }
  }

  String? _conversionLabel(double? grams) {
    if (grams == null) return null;
    // In a piece/serving unit, the helpful conversion is the plain grams.
    if (_unit != AmountUnit.grams) {
      return '${formatAmount(grams)} g${_item.isCookedBasis ? ' cooked' : ''}';
    }
    // For a cooked-basis food, the helpful conversion is the other weight
    // basis ([grams] is always the cooked-equivalent weight).
    if (_item.isCookedBasis) {
      return _rawWeight
          ? '≈ ${formatAmount(grams)} g cooked'
          : '≈ ${formatAmount(grams / kCookedYieldFactor)} g raw';
    }
    // In grams, show the closest piece (preferred) or serving equivalent.
    if (_hasPiece) {
      final count = grams / _piece!;
      return '≈ ${formatAmount(count)} ${pluralize(_item.pieceUnit!, count)}';
    }
    if (_hasServing) {
      final servings = grams / _serving!;
      return '≈ ${formatAmount(servings)} ${pluralize('serving', servings)}';
    }
    return null;
  }
}

class MacroPill extends StatelessWidget {
  const MacroPill({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.unit = 'g',
  });

  final String label;

  /// Amount in [unit]; null when the food carries no data for this nutrient.
  final double? value;
  final Color color;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amount = value;
    // Grams read as "12g"; other units keep a thin space ("320 mg").
    final valueText = amount == null
        ? '—'
        : '${formatNutrientValue(amount)}${unit == 'g' ? 'g' : ' $unit'}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          valueText,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
