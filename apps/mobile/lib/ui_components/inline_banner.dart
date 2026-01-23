import 'package:flutter/material.dart';

import '../ui_system/tokens.dart';

enum InlineBannerTone { info, error }

class InlineBanner extends StatelessWidget {
  const InlineBanner({
    super.key,
    required this.message,
    this.tone = InlineBannerTone.info,
    this.icon,
  });

  final String message;
  final InlineBannerTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bool isError = tone == InlineBannerTone.error;
    final Color background = isError
        ? colorScheme.errorContainer
        : colorScheme.secondaryContainer;
    final Color foreground =
        isError ? colorScheme.onErrorContainer : colorScheme.onSecondaryContainer;
    final IconData displayIcon =
        icon ?? (isError ? Icons.error_outline : Icons.info_outline);

    return Semantics(
      container: true,
      liveRegion: isError,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: colorScheme.outline.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(displayIcon, color: foreground),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
