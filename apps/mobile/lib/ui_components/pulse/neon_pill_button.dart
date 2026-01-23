import 'package:flutter/material.dart';

import '../../ui_system/pulse_theme.dart';
import '../../ui_system/tokens.dart';

class NeonPillButton extends StatefulWidget {
  const NeonPillButton({
    super.key,
    required this.child,
    this.onPressed,
    this.isLoading = false,
    this.expand = true,
    this.compact = false,
    this.glowColor,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final bool isLoading;
  final bool expand;
  final bool compact;
  final Color? glowColor;

  @override
  State<NeonPillButton> createState() => _NeonPillButtonState();
}

class _NeonPillButtonState extends State<NeonPillButton> {
  bool _pressed = false;

  void _handleTapDown(TapDownDetails details) {
    if (!_isEnabled) {
      return;
    }
    setState(() {
      _pressed = true;
    });
  }

  void _handleTapCancel() {
    if (!_pressed) {
      return;
    }
    setState(() {
      _pressed = false;
    });
  }

  void _handleTapUp(TapUpDetails details) {
    if (!_pressed) {
      return;
    }
    setState(() {
      _pressed = false;
    });
  }

  bool get _isEnabled => widget.onPressed != null && !widget.isLoading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effects = PulseTheme.effectsOf(context);
    final glow = widget.glowColor ?? scheme.primary;
    final enabled = _isEnabled;
    final baseColor = enabled ? scheme.primary : scheme.surfaceContainerHigh;
    final contentColor = enabled ? scheme.onPrimary : scheme.onSurfaceVariant;
    final glowSigma = _pressed ? effects.glowLow : effects.glowMedium;
    final glowOpacity = enabled ? (_pressed ? 0.25 : 0.55) : 0.0;
    final textStyle = widget.compact
        ? Theme.of(context).textTheme.labelLarge
        : Theme.of(context).textTheme.titleMedium;
    final padding = widget.compact
        ? const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          )
        : const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.md,
          );

    final Widget content = widget.isLoading
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: contentColor,
            ),
          )
        : DefaultTextStyle(
            style: textStyle?.copyWith(
                  color: contentColor,
                  fontWeight: FontWeight.w700,
                ) ??
                TextStyle(color: contentColor),
            child: IconTheme(
              data: IconThemeData(color: contentColor),
              child: widget.child,
            ),
          );

    final button = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      padding: padding,
      decoration: BoxDecoration(
        color: baseColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: enabled
              ? glow.withValues(alpha: 0.55)
              : scheme.outlineVariant.withValues(alpha: 0.6),
        ),
        boxShadow: [
          if (enabled)
            BoxShadow(
              color: glow.withValues(alpha: glowOpacity),
              blurRadius: glowSigma,
              spreadRadius: 1,
            ),
          if (enabled)
            BoxShadow(
              color: glow.withValues(alpha: glowOpacity * 0.4),
              blurRadius: glowSigma * 2.2,
              spreadRadius: 4,
            ),
        ],
      ),
      child: Center(child: content),
    );

    final constrained = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: button,
    );

    final expanded = widget.expand
        ? SizedBox(width: double.infinity, child: constrained)
        : constrained;

    return Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        onTap: enabled ? widget.onPressed : null,
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        behavior: HitTestBehavior.opaque,
        child: expanded,
      ),
    );
  }
}
