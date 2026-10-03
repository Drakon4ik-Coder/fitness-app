import 'package:flutter/widgets.dart';

/// A label/value pair that sits on one line pushed to opposite edges while it
/// fits, and drops [trailing] onto its own line below [leading] once it
/// doesn't — instead of ellipsizing either side.
///
/// Narrow slots (focus-nutrient tiles, meal-card headings) only run out of
/// room at large system text scales (KAN-40's 2.0x), where an ellipsized
/// "PRO…" or "Brea…" loses the very word the user scaled text up to read.
/// Each side also scales down as a last resort, so a single word wider than
/// the whole slot shrinks intact rather than breaking mid-word.
class SpreadOrStack extends StatelessWidget {
  const SpreadOrStack({
    super.key,
    required this.leading,
    required this.trailing,
    this.spacing = 4,
  });

  final Widget leading;
  final Widget trailing;

  /// Minimum gap kept between the two sides while they share a line.
  final double spacing;

  @override
  Widget build(BuildContext context) {
    // Full width: Wrap otherwise shrink-wraps its run under loose
    // constraints, and spaceBetween would have no free space to distribute.
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: spacing,
        children: [
          FittedBox(fit: BoxFit.scaleDown, child: leading),
          FittedBox(fit: BoxFit.scaleDown, child: trailing),
        ],
      ),
    );
  }
}
