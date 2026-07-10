import 'package:flutter/material.dart';

import '../ui_system/tokens.dart';

/// Inline text link rendered as a real button.
///
/// A bare [GestureDetector] over a [Text] announces as plain text to screen
/// readers, gives no press feedback, and its touch target is only as tall as
/// the glyphs — this exists so "Create account"-style links get button
/// semantics, a disabled state, and a 44pt target (KAN-58).
class LinkButton extends StatelessWidget {
  const LinkButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.textStyle,
  });

  final String label;

  /// Null disables the link (e.g. while a submit is in flight).
  final VoidCallback? onPressed;

  /// Defaults to bodyMedium/w600, the weight of the surrounding footer copy.
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        // The app theme's TextButton stretches to full width, which the
        // unbounded Rows these links sit in can't satisfy; keep a compact
        // 44pt target instead.
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        textStyle:
            textStyle ??
            theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}
