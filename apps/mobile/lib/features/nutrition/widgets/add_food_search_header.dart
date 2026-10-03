import 'dart:math' show max;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../../../ui_components/ui_components.dart';
import '../../../ui_system/tokens.dart';

// Add-food page search strip and its rate-limit countdown (KAN-124:
// extracted from add_food_page.dart).

/// The search strip that pins below the app bar while results scroll under it
/// (KAN-60). Carries the inline banner (errors stay visible next to the field
/// that caused them) plus the rate-limit countdown notice (KAN-96), and
/// always reserves the 2px activity strip so the pinned extent doesn't jump
/// when a live search starts.
class AddFoodSearchHeader extends StatelessWidget {
  const AddFoodSearchHeader({
    super.key,
    required this.controller,
    required this.onScan,
    required this.isLoading,
    required this.message,
    required this.messageTone,
    required this.rateLimit,
  });

  final TextEditingController controller;
  final VoidCallback? onScan;
  final bool isLoading;
  final String? message;
  final InlineBannerTone? messageTone;

  /// Live pause countdown; the notice listens to it directly so a tick never
  /// rebuilds the page (KAN-124).
  final ValueListenable<RateLimitCountdown> rateLimit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (message != null) ...[
              InlineBanner(
                message: message!,
                tone: messageTone ?? InlineBannerTone.info,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            GlassSearchBar(controller: controller, onScan: onScan),
            ValueListenableBuilder<RateLimitCountdown>(
              valueListenable: rateLimit,
              builder: (context, countdown, _) {
                if (!countdown.isActive) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: _RateLimitNotice(
                    // Both budgets share one banner; when both are paused
                    // the longer window is the honest countdown (KAN-96).
                    secondsLeft: max(
                      countdown.offSeconds,
                      countdown.fatsecretSeconds,
                    ),
                    // OFF's pause is the one that greys out the scan button
                    // above, so the copy must say why.
                    scanPaused: countdown.offSeconds > 0,
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.xs),
            SizedBox(
              height: 2,
              child: isLoading
                  ? LinearProgressIndicator(
                      minHeight: 2,
                      color: scheme.primary,
                      backgroundColor: scheme.surfaceContainer,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Seconds left on each online budget's pause (KAN-96); 0 = that budget is
/// free. Immutable so the notifier only fires on real changes.
@immutable
class RateLimitCountdown {
  const RateLimitCountdown({this.offSeconds = 0, this.fatsecretSeconds = 0});

  final int offSeconds;
  final int fatsecretSeconds;

  bool get isActive => offSeconds > 0 || fatsecretSeconds > 0;

  RateLimitCountdown copyWith({int? offSeconds, int? fatsecretSeconds}) =>
      RateLimitCountdown(
        offSeconds: offSeconds ?? this.offSeconds,
        fatsecretSeconds: fatsecretSeconds ?? this.fatsecretSeconds,
      );

  /// One second later: each running window shrinks, never below zero.
  RateLimitCountdown tick() => RateLimitCountdown(
    offSeconds: offSeconds > 0 ? offSeconds - 1 : 0,
    fatsecretSeconds: fatsecretSeconds > 0 ? fatsecretSeconds - 1 : 0,
  );

  @override
  bool operator ==(Object other) =>
      other is RateLimitCountdown &&
      other.offSeconds == offSeconds &&
      other.fatsecretSeconds == fatsecretSeconds;

  @override
  int get hashCode => Object.hash(offSeconds, fatsecretSeconds);
}

/// Persistent "search paused" notice with a live countdown (KAN-96): while an
/// online budget is exhausted the user sees why results stopped arriving —
/// and, for OFF, why the scan button greyed out — instead of silence. The
/// copy tracks which budget is actually paused: if OFF's window elapses
/// before FatSecret's, scan re-enables and the text drops the scan mention
/// on the same tick.
class _RateLimitNotice extends StatelessWidget {
  const _RateLimitNotice({required this.secondsLeft, required this.scanPaused});

  final int secondsLeft;
  final bool scanPaused;

  @override
  Widget build(BuildContext context) {
    // "Restaurant search" is the FatSecret leg's product framing (KAN-67);
    // backend + packaged-food search keep working during its pause.
    final scope = scanPaused
        ? 'Online search and barcode scan paused'
        : 'Restaurant search paused';
    return InlineBanner(
      message: '$scope — resuming in ${secondsLeft}s',
      icon: Icons.hourglass_top,
    );
  }
}
