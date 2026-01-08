import 'package:flutter/material.dart';

import '../ui_system/tokens.dart';

class AppSection extends StatelessWidget {
  const AppSection({
    super.key,
    required this.title,
    this.child,
    this.trailing,
    this.padding,
  });

  final String title;
  final Widget? child;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium,
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );

    return Padding(
      padding: padding ?? EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          if (child != null) ...[
            const SizedBox(height: AppSpacing.sm),
            child!,
          ],
        ],
      ),
    );
  }
}
