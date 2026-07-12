import 'package:flutter/material.dart';

import '../../ui_system/tokens.dart';

/// A square, icon-only outlined button for third-party sign-in providers
/// (Google today; Apple / Facebook / etc. can sit beside it later).
class SocialAuthButton extends StatelessWidget {
  const SocialAuthButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.semanticLabel,
    this.size = 56,
  });

  /// The provider glyph (e.g. the Google "G").
  final Widget child;
  final VoidCallback? onPressed;
  final String? semanticLabel;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.md);

    return Semantics(
      button: true,
      label: semanticLabel,
      child: SizedBox(
        width: size,
        height: size,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(borderRadius: radius),
            side: BorderSide(color: scheme.outline.withValues(alpha: 0.5)),
            foregroundColor: scheme.onSurface,
          ),
          child: child,
        ),
      ),
    );
  }
}
