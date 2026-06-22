import 'package:flutter/material.dart';

import 'glowing_progress_ring.dart';

/// The SYMBIO logo mark, drawn entirely with vectors so it stays crisp at any
/// size and follows the theme colors.
///
/// It mirrors the launcher icon: a glowing neon ring with the brand "S" at its
/// centre on a dark disc. Because it is painted (not a raster asset) it never
/// pixelates, even when scaled up.
class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    this.size = 84,
  });

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Dark disc backdrop so the ring + letter read as a badge.
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.surfaceContainerLowest,
            ),
            margin: EdgeInsets.all(size * 0.06),
          ),
          GlowingProgressRing(
            progress: 1.0,
            size: size,
            thickness: size * 0.07,
            trackColor: Colors.transparent,
            progressColor: scheme.primary,
            glowColor: scheme.primary,
            glowLevel: PulseGlowLevel.high,
          ),
          Text(
            'S',
            style: Theme.of(context).textTheme.displayLarge?.copyWith(
              fontSize: size * 0.5,
              fontWeight: FontWeight.w800,
              color: scheme.primary,
              height: 1,
              shadows: [
                Shadow(
                  color: scheme.primary.withValues(alpha: 0.5),
                  blurRadius: size * 0.12,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
