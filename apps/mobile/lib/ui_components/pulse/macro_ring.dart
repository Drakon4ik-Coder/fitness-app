import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui_system/tokens.dart';
import 'glowing_progress_ring.dart';

class MacroRing extends StatelessWidget {
  const MacroRing({
    super.key,
    required this.label,
    required this.current,
    required this.goal,
    this.color,
    this.trackColor,
    this.size = 84,
    this.thickness = 8,
  });

  final String label;
  final int current;
  final int goal;
  final Color? color;
  final Color? trackColor;
  final double size;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress =
        goal <= 0 ? 0.0 : math.min(1.0, current / goal).toDouble();
    final labelStyle = theme.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w600,
      color: theme.colorScheme.onSurface,
    );
    final valueStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final valueLabel = '$current/$goal g';

    return SizedBox(
      height: size,
      width: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          GlowingProgressRing(
            progress: progress,
            size: size,
            thickness: thickness,
            trackColor: trackColor,
            progressColor: color,
            glowColor: color,
            glowLevel: PulseGlowLevel.low,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text.rich(
                TextSpan(
                  text: '$label\n',
                  style: labelStyle,
                  children: [
                    TextSpan(
                      text: valueLabel,
                      style: valueStyle,
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
