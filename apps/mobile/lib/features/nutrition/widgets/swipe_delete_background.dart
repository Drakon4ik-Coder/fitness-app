import 'package:flutter/material.dart';

import '../../../ui_system/tokens.dart';

/// The red "delete" reveal behind a swipe-to-delete row (KAN-39). The row
/// itself tracks the finger; this stays put underneath, so the further the
/// swipe travels the more of it shows — the swipe-clarity affordance that
/// replaced the persistent per-row delete buttons.
class SwipeDeleteBackground extends StatelessWidget {
  const SwipeDeleteBackground({super.key, this.borderRadius});

  /// Matches the dismissed row's corner radius so the reveal doesn't poke out
  /// past a rounded card; null for edge-to-edge list rows.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.error,
        borderRadius: borderRadius,
      ),
      child: Icon(Icons.delete_outline, color: scheme.onError),
    );
  }
}
