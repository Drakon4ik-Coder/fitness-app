import 'package:flutter/material.dart';

import '../../../ui_system/lumina_health_theme.dart';

/// Guards a settings sub-page against losing edits: while [dirty] is true the
/// system back gesture and app-bar back button ask before discarding.
///
/// Only `maybePop` routes are intercepted, so a successful save can still call
/// `Navigator.pop(result)` directly without tripping the guard.
class UnsavedChangesScope extends StatelessWidget {
  const UnsavedChangesScope({
    super.key,
    required this.dirty,
    required this.child,
  });

  final bool dirty;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final discard = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Discard changes?'),
            content: const Text("Your edits haven't been saved."),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Keep editing'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                style: TextButton.styleFrom(
                  foregroundColor: LuminaHealthColors.error,
                ),
                child: const Text('Discard'),
              ),
            ],
          ),
        );
        if (discard == true) navigator.pop();
      },
      child: child,
    );
  }
}
