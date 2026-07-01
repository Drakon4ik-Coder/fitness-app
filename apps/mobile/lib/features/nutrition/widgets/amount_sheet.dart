import 'package:flutter/material.dart';

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
        child: FoodImage(url: url),
      ),
    );
  }
}

/// Fills a food card with its photo. Shows a neutral food placeholder when no
/// image URL is known, and — when an image URL exists but fails to load — a
/// tappable red reload button that evicts the cached failure and retries.
class FoodImage extends StatefulWidget {
  const FoodImage({super.key, required this.url});

  final String? url;

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
    return Image.network(
      url,
      key: ValueKey('$url#$_attempt'),
      fit: BoxFit.cover,
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

/// Outcome of the amount bottom sheet: either a saved [grams] amount or a
/// request to [removed] the item from the meal.
class AmountResult {
  const AmountResult._({this.grams, this.removed = false});

  factory AmountResult.save(double grams) => AmountResult._(grams: grams);
  factory AmountResult.remove() => const AmountResult._(removed: true);

  final double? grams;
  final bool removed;
}

/// Opens the amount editor as a modal bottom sheet and resolves with the user's
/// choice ([AmountResult]) or null if they dismissed it.
Future<AmountResult?> showAmountSheet({
  required BuildContext context,
  required FoodItem item,
  required double initialGrams,
  required bool isEditing,
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
    ),
  );
}

class AmountSheet extends StatefulWidget {
  const AmountSheet({
    super.key,
    required this.item,
    required this.initialGrams,
    required this.isEditing,
  });

  final FoodItem item;
  final double initialGrams;
  final bool isEditing;

  @override
  State<AmountSheet> createState() => _AmountSheetState();
}

class _AmountSheetState extends State<AmountSheet> {
  late final TextEditingController _controller;
  late AmountUnit _unit;
  bool _showAllNutrients = false;

  double? get _serving {
    final serving = widget.item.servingSizeG;
    return (serving != null && serving > 0) ? serving : null;
  }

  double? get _piece {
    final piece = widget.item.gramsPerPiece;
    return (piece != null && piece > 0 && widget.item.pieceUnit != null)
        ? piece
        : null;
  }

  bool get _hasServing => _serving != null;
  bool get _hasPiece => _piece != null;

  String? get _imageUrl {
    final url = widget.item.imageUrl?.trim();
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
        return 1;
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

  void _submit() {
    final grams = _grams;
    if (grams == null) return;
    Navigator.of(context).pop(AmountResult.save(grams));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final grams = _grams;
    final factor = (grams ?? 0) / 100.0;

    final kcal = ((widget.item.kcal100g ?? 0) * factor).round();
    final protein = (widget.item.proteinG100g ?? 0) * factor;
    final carbs = (widget.item.carbsG100g ?? 0) * factor;
    final fats = (widget.item.fatG100g ?? 0) * factor;

    // Full breakdown scaled to the current amount, for the "check the nutrition
    // before adding" disclosure. Only offered when the food actually carries
    // detail beyond the macro pills already shown.
    final nutrientTotals = grams == null
        ? const <NutrientTotal>[]
        : nutrientTotalsForItem(widget.item, grams);
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
            Row(
              children: [
                FoodThumb(url: _imageUrl, size: 48),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.item.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.item.kcal100g == null
                            ? 'Calories per 100g unavailable'
                            : '${widget.item.kcal100g!.round()} kcal per 100g',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),

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
            Center(
              child: Text(
                conversion == null ? unitLabel : '$unitLabel  •  $conversion',
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
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
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
                  Row(
                    children: [
                      MacroPill(
                        label: 'P',
                        value: protein,
                        color: scheme.secondary,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      MacroPill(
                        label: 'C',
                        value: carbs,
                        color: scheme.tertiary,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      MacroPill(
                        label: 'F',
                        value: fats,
                        color: scheme.primary,
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
        final noun = '${widget.item.pieceUnit!}s';
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
        return pluralize(widget.item.pieceUnit!, count);
      case AmountUnit.servings:
        return pluralize('serving', count);
      case AmountUnit.grams:
        return 'grams';
    }
  }

  String? _conversionLabel(double? grams) {
    if (grams == null) return null;
    // In a piece/serving unit, the helpful conversion is the raw grams.
    if (_unit != AmountUnit.grams) {
      return '${formatAmount(grams)} g';
    }
    // In grams, show the closest piece (preferred) or serving equivalent.
    if (_hasPiece) {
      final count = grams / _piece!;
      return '≈ ${formatAmount(count)} ${pluralize(widget.item.pieceUnit!, count)}';
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
  });

  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          '${value.round()}g',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
