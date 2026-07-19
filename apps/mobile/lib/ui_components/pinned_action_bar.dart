import 'package:flutter/material.dart';

import '../ui_system/tokens.dart';

/// Pins a page's primary action to the bottom of the screen.
///
/// Hand this to [AppScaffold.bottomNavigationBar] instead of appending the
/// action to the page's scrollable body. A Scaffold does not lift its
/// bottom-navigation bar above the keyboard, so the explicit keyboard inset
/// keeps form actions reachable while a text field has focus.
class PinnedActionBar extends StatelessWidget {
  const PinnedActionBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          border: Border(
            top: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.4),
            ),
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
      ),
    );
  }
}
