import 'package:flutter/material.dart';
import '../../../ui_system/lumina_health_theme.dart';
import '../../../ui_system/tokens.dart';

// Today page: pinned date bar and the pending-sync chip (KAN-124:
// extracted from nutrition_today_page.dart).

/// Pinned compact date bar so the viewed day is visible at any scroll
/// position. Transparent at rest (the hero gradient shows through); opaque
/// once meal cards scroll under it so they don't visually collide. Reserves
/// a fixed slot for the loading bar so its appearance doesn't shift content
/// (KAN-25).
class TodayDateBar extends StatelessWidget {
  const TodayDateBar({
    super.key,
    required this.dateLabel,
    required this.isToday,
    required this.showSpinner,
    required this.onPreviousDay,
    required this.onNextDay,
    required this.onPickDate,
    required this.onSetToday,
  });

  final String dateLabel;
  final bool isToday;
  final bool showSpinner;
  final VoidCallback onPreviousDay;
  final VoidCallback onNextDay;
  final VoidCallback onPickDate;
  final VoidCallback onSetToday;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SliverAppBar(
      pinned: true,
      primary: false,
      automaticallyImplyLeading: false,
      toolbarHeight: 52,
      titleSpacing: AppSpacing.sm,
      backgroundColor: WidgetStateColor.resolveWith(
        (states) => states.contains(WidgetState.scrolledUnder)
            ? scheme.surface
            : Colors.transparent,
      ),
      title: Row(
        children: [
          IconButton(
            tooltip: 'Previous day',
            icon: const Icon(Icons.chevron_left),
            color: LuminaHealthColors.primary,
            onPressed: onPreviousDay,
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: InkWell(
                    // No onDoubleTap here: a second recognizer forces every
                    // tap to wait out the ~300ms disambiguation window
                    // (KAN-57). The Today chip covers the jump-to-today case.
                    onTap: onPickDate,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xs,
                      ),
                      child: Text(
                        dateLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: LuminaHealthColors.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                if (!isToday)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.sm),
                    child: ActionChip(
                      key: const Key('todayChip'),
                      tooltip: 'Back to today',
                      onPressed: onSetToday,
                      visualDensity: VisualDensity.compact,
                      backgroundColor: scheme.primary.withValues(alpha: 0.1),
                      side: BorderSide(
                        color: scheme.primary.withValues(alpha: 0.3),
                      ),
                      label: Text(
                        'Today',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Next day',
            icon: const Icon(Icons.chevron_right),
            color: isToday ? null : LuminaHealthColors.primary,
            onPressed: isToday ? null : onNextDay,
          ),
        ],
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(2),
        child: SizedBox(
          height: 2,
          child: showSpinner
              ? Padding(
                  key: const Key("nutritionLoadingSpinner"),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    color: scheme.primary,
                    backgroundColor: scheme.surfaceContainer,
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

/// Subtle "waiting to sync" indicator under the date bar (KAN-56): offline
/// writes land in the outbox and the day still says "Meal logged", so this is
/// the only signal that other devices won't see the change until this one
/// reconnects. Disappears once the outbox drains.
class PendingSyncChip extends StatelessWidget {
  const PendingSyncChip({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = count == 1
        ? '1 change waiting to sync'
        : '$count changes waiting to sync';
    return Center(
      child: Container(
        key: const Key('pendingSyncChip'),
        margin: const EdgeInsets.only(top: AppSpacing.xs),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: LuminaHealthColors.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_upload_outlined,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
