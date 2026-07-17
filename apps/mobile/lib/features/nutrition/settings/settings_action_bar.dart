import 'package:flutter/material.dart';

import '../../../ui_system/tokens.dart';

/// Pins a settings form's primary action to the bottom of the screen so it is
/// always reachable without scrolling the form (KAN-94). Hand it to
/// `AppScaffold.bottomNavigationBar` instead of appending the button to the
/// page's ListView.
///
/// Living outside the scrollable body also fixes the keyboard trade-off in one
/// place: the Scaffold resizes only the body above the keyboard, so fields
/// stay reachable while typing and the bar never eats viewport — it reappears
/// the moment the keyboard is dismissed. Every settings form gets the same
/// behavior.
class SettingsActionBar extends StatelessWidget {
  const SettingsActionBar({super.key, required this.child});

  /// The form's primary action, typically an `AppPrimaryButton`.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      // Same surface + hairline language as the add-food log bar, so pinned
      // action bars read identically across the app.
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: child,
        ),
      ),
    );
  }
}
