import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../ui_system/pulse_theme.dart';

enum PulseGlowLevel { low, medium, high }

class GlowingProgressRing extends StatelessWidget {
  const GlowingProgressRing({
    super.key,
    required this.progress,
    this.size = 180,
    this.thickness = 12,
    this.trackColor,
    this.progressColor,
    this.glowColor,
    this.glowLevel = PulseGlowLevel.medium,
  });

  final double progress;
  final double size;
  final double thickness;
  final Color? trackColor;
  final Color? progressColor;
  final Color? glowColor;
  final PulseGlowLevel glowLevel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effects = PulseTheme.effectsOf(context);
    final effectiveProgress = progress.clamp(0.0, 1.0);
    final glowSigma = switch (glowLevel) {
      PulseGlowLevel.low => effects.glowLow,
      PulseGlowLevel.medium => effects.glowMedium,
      PulseGlowLevel.high => effects.glowHigh,
    };

    return CustomPaint(
      size: Size.square(size),
      painter: _GlowingProgressRingPainter(
        progress: effectiveProgress,
        thickness: thickness,
        trackColor: trackColor ?? effects.ringTrackColor,
        progressColor: progressColor ?? scheme.primary,
        glowColor: glowColor ?? progressColor ?? scheme.primary,
        glowSigma: glowSigma,
      ),
    );
  }
}

class _GlowingProgressRingPainter extends CustomPainter {
  _GlowingProgressRingPainter({
    required this.progress,
    required this.thickness,
    required this.trackColor,
    required this.progressColor,
    required this.glowColor,
    required this.glowSigma,
  });

  final double progress;
  final double thickness;
  final Color trackColor;
  final Color progressColor;
  final Color glowColor;
  final double glowSigma;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - thickness) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final startAngle = -math.pi / 2;
    final sweepAngle = 2 * math.pi * progress;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round
      ..color = trackColor;
    canvas.drawCircle(center, radius, trackPaint);

    if (progress <= 0) {
      return;
    }

    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness + 4
      ..strokeCap = StrokeCap.round
      ..color = glowColor.withValues(alpha: 0.55)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, glowSigma);
    canvas.drawArc(rect, startAngle, sweepAngle, false, glowPaint);

    final progressPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round
      ..color = progressColor;
    canvas.drawArc(rect, startAngle, sweepAngle, false, progressPaint);
  }

  @override
  bool shouldRepaint(covariant _GlowingProgressRingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.thickness != thickness ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.progressColor != progressColor ||
        oldDelegate.glowColor != glowColor ||
        oldDelegate.glowSigma != glowSigma;
  }
}
