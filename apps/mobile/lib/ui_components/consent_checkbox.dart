import 'package:flutter/material.dart';

import '../core/legal_links.dart';
import '../ui_system/tokens.dart';

/// Checkbox row for legal consents (KAN-103), used by signup and the
/// blocking consent screen.
///
/// Always starts unticked — pre-ticked boxes are not valid consent (GDPR
/// Recital 32) — and the label is rich text so document links can sit inline
/// via [ConsentCheckbox.link].
class ConsentCheckbox extends StatelessWidget {
  const ConsentCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });

  final bool value;

  /// Null disables the checkbox (e.g. while a submit is in flight).
  final ValueChanged<bool>? onChanged;

  /// Label content; wrap tappable document links with [link].
  final InlineSpan label;

  /// An inline tappable link for [label]. A WidgetSpan rather than a
  /// TapGestureRecognizer so callers don't have to manage recognizer
  /// lifecycles; Semantics(link:) keeps it announced as a link even though
  /// the tap target is only text-height (the row's checkbox provides the
  /// 48pt target, and a taller inline target would break the line layout).
  static InlineSpan link(
    BuildContext context,
    String text, {
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: Semantics(
        link: true,
        child: GestureDetector(
          onTap: onTap,
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
              decorationColor: theme.colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Checkbox(
          value: value,
          onChanged: onChanged == null
              ? null
              : (checked) => onChanged!(checked ?? false),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          // Top padding aligns the first text line with the checkbox glyph,
          // which Material centers inside its 48pt tap target.
          child: Padding(
            padding: const EdgeInsets.only(top: AppSpacing.md),
            child: Text.rich(
              TextSpan(
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                children: [label],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The two policy consents (KAN-103) with their canonical wording, shared by
/// the signup form and the blocking consent screen so the texts can't drift
/// apart. Kept as two separate checkboxes: GDPR Art. 9 requires the explicit
/// health-data consent to stay distinct from the general ToS/privacy
/// acceptance.
class PolicyConsentChecks extends StatelessWidget {
  const PolicyConsentChecks({
    super.key,
    required this.acceptedTerms,
    required this.acceptedHealthData,
    required this.onTermsChanged,
    required this.onHealthDataChanged,
    required this.openDocument,
  });

  final bool acceptedTerms;
  final bool acceptedHealthData;

  /// Null disables the checkboxes (e.g. while a submit is in flight).
  final ValueChanged<bool>? onTermsChanged;
  final ValueChanged<bool>? onHealthDataChanged;

  /// Opens a linked legal document (ToS / privacy policy) by URL.
  final void Function(String url) openDocument;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConsentCheckbox(
          value: acceptedTerms,
          onChanged: onTermsChanged,
          label: TextSpan(
            children: [
              const TextSpan(text: 'I agree to the '),
              ConsentCheckbox.link(
                context,
                'Terms of Service',
                onTap: () => openDocument(kTermsOfServiceUrl),
              ),
              const TextSpan(text: ' and '),
              ConsentCheckbox.link(
                context,
                'Privacy Policy',
                onTap: () => openDocument(kPrivacyPolicyUrl),
              ),
              const TextSpan(text: '.'),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        ConsentCheckbox(
          value: acceptedHealthData,
          onChanged: onHealthDataChanged,
          label: const TextSpan(
            text:
                'I consent to Symbio processing the nutrition and health '
                'data I log (meals, calories, goals) to provide tracking '
                'and statistics.',
          ),
        ),
      ],
    );
  }
}
