import 'dart:ui';

import 'package:flutter/material.dart';

import '../../ui_system/pulse_theme.dart';
import '../../ui_system/tokens.dart';

class GlassMealCard extends StatelessWidget {
  const GlassMealCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effects = PulseTheme.effectsOf(context);
    final radius = borderRadius ?? BorderRadius.circular(AppRadius.lg);
    final overlayColor =
        scheme.onSurface.withValues(alpha: effects.glassOverlayOpacity);
    final borderColor = scheme.outlineVariant.withValues(alpha: 0.6);

    final content = Padding(
      padding: padding ?? const EdgeInsets.all(AppSpacing.lg),
      child: child,
    );

    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: overlayColor,
        borderRadius: radius,
        border: Border.all(color: borderColor),
      ),
      child: content,
    );

    final blurred = BackdropFilter(
      filter: ImageFilter.blur(
        sigmaX: effects.blurRadius,
        sigmaY: effects.blurRadius,
      ),
      child: decorated,
    );

    if (onTap == null) {
      return ClipRRect(
        borderRadius: radius,
        child: blurred,
      );
    }

    return ClipRRect(
      borderRadius: radius,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: blurred,
        ),
      ),
    );
  }
}
