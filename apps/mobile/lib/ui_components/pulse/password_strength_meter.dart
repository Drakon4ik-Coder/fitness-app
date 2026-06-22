import 'package:flutter/material.dart';

import '../../ui_system/tokens.dart';

/// Advisory strength indicator shown under the register password field.
///
/// It grades the password on four checks (length, letter, number, symbol),
/// shows a segmented bar plus a requirement checklist. Purely informational —
/// the form's own validator still enforces the hard minimum.
class PasswordStrengthMeter extends StatelessWidget {
  const PasswordStrengthMeter({
    super.key,
    required this.password,
  });

  final String password;

  bool get _hasLength => password.length >= 8;
  bool get _hasLetter => RegExp(r'[A-Za-z]').hasMatch(password);
  bool get _hasNumber => RegExp(r'\d').hasMatch(password);
  bool get _hasSymbol => RegExp(r'[^A-Za-z0-9]').hasMatch(password);

  int get _score =>
      (_hasLength ? 1 : 0) +
      (_hasLetter ? 1 : 0) +
      (_hasNumber ? 1 : 0) +
      (_hasSymbol ? 1 : 0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Map score (0-4) to a label and color.
    final (String label, Color color) = switch (_score) {
      <= 1 => ('Weak', scheme.error),
      2 => ('Fair', scheme.tertiary),
      3 => ('Good', scheme.primary),
      _ => ('Strong', scheme.primary),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            for (var i = 0; i < 4; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 4,
                  decoration: BoxDecoration(
                    color: i < _score
                        ? color
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Text(
              password.isEmpty ? 'Use 8+ characters' : label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: password.isEmpty ? scheme.onSurfaceVariant : color,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            _Hint(label: '8+', satisfied: _hasLength),
            const SizedBox(width: AppSpacing.sm),
            _Hint(label: 'number', satisfied: _hasNumber),
            const SizedBox(width: AppSpacing.sm),
            _Hint(label: 'letter', satisfied: _hasLetter),
          ],
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.label, required this.satisfied});

  final String label;
  final bool satisfied;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = satisfied ? scheme.primary : scheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          satisfied ? Icons.check_circle : Icons.circle_outlined,
          size: 12,
          color: color,
        ),
        const SizedBox(width: 2),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
  }
}
