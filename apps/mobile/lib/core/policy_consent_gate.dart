import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import '../ui_components/ui_components.dart';
import '../ui_system/tokens.dart';
import 'auth_service.dart';

Future<bool> _openExternal(Uri url) => url_launcher.launchUrl(
  url,
  mode: url_launcher.LaunchMode.externalApplication,
);

/// One-time blocking policy-consent gate (KAN-103): renders [child]
/// immediately and swaps in a full-screen consent page when `/auth/me`
/// reports the user hasn't accepted the current policy version — the path by
/// which Google sign-ins (no signup checkboxes) and existing users after a
/// policy bump give their consent.
///
/// Fail-open by design, like UpdateGate: this is an offline-first app, so an
/// unreachable backend or a stale token must never lock the user out — the
/// server refuses gated writes anyway and the outbox replays them after
/// acceptance. Only the definitive verdict "accepted != current" blocks.
/// Re-checks on app resume so a policy bump mid-session (which the exempt
/// /auth/me won't 403 on, but gated endpoints will) surfaces the screen
/// without needing a global 403 interceptor.
class PolicyConsentGate extends StatefulWidget {
  const PolicyConsentGate({
    super.key,
    required this.accessToken,
    required this.child,
    this.authService,
    Future<bool> Function(Uri url)? openUrl,
  }) : openUrl = openUrl ?? _openExternal;

  final String accessToken;
  final Widget child;

  /// Injected by tests; defaults to the real backend client.
  final AuthService? authService;

  /// Opens the linked legal documents; tests pass a fake to capture it.
  final Future<bool> Function(Uri url) openUrl;

  @override
  State<PolicyConsentGate> createState() => _PolicyConsentGateState();
}

class _PolicyConsentGateState extends State<PolicyConsentGate>
    with WidgetsBindingObserver {
  late final AuthService _authService = widget.authService ?? AuthService();

  bool _consentRequired = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _check() async {
    // fetchMe returns null on any failure (offline, stale token, server
    // error) — all fail open per the class contract.
    final info = await _authService.fetchMe(accessToken: widget.accessToken);
    if (!mounted || info == null) return;
    final required =
        info.currentPolicyVersion.isNotEmpty &&
        info.acceptedPolicyVersion != info.currentPolicyVersion;
    // Also unblocks (required == false) when a resume-check learns the user
    // consented on another device.
    if (required != _consentRequired) {
      setState(() => _consentRequired = required);
    }
  }

  Future<void> _accept() async {
    await _authService.acceptPolicy(accessToken: widget.accessToken);
    if (mounted) setState(() => _consentRequired = false);
  }

  @override
  Widget build(BuildContext context) => _consentRequired
      ? PolicyConsentPage(onAccept: _accept, openUrl: widget.openUrl)
      : widget.child;
}

/// The full-screen blocking consent page the gate swaps in. Mirrors the two
/// signup checkboxes: ToS+privacy acceptance and the separate explicit
/// health-data consent, both starting unticked.
class PolicyConsentPage extends StatefulWidget {
  const PolicyConsentPage({
    super.key,
    required this.onAccept,
    required this.openUrl,
  });

  /// Posts the acceptance; throws [AuthException] on failure (surfaced as an
  /// inline error with the button re-enabled for retry).
  final Future<void> Function() onAccept;

  final Future<bool> Function(Uri url) openUrl;

  @override
  State<PolicyConsentPage> createState() => _PolicyConsentPageState();
}

class _PolicyConsentPageState extends State<PolicyConsentPage> {
  bool _acceptedTerms = false;
  bool _acceptedHealthData = false;
  bool _isSubmitting = false;
  String? _errorMessage;

  Future<void> _submit() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      await widget.onAccept();
      // On success the gate unmounts this page; no state to restore.
    } on AuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.message;
        _isSubmitting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Could not save your consent. Please try again.';
        _isSubmitting = false;
      });
    }
  }

  Future<void> _openLegalDocument(String url) async {
    var opened = false;
    try {
      opened = await widget.openUrl(Uri.parse(url));
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.xl),
              const Center(child: BrandMark()),
              const SizedBox(height: AppSpacing.xxl),
              Text(
                'Before you continue',
                style: theme.textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Symbio stores the meals, nutrition data and goals you log — '
                'that is health data, so we need your explicit consent. '
                'Please review and accept to keep using Symbio.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              PolicyConsentChecks(
                acceptedTerms: _acceptedTerms,
                acceptedHealthData: _acceptedHealthData,
                onTermsChanged: _isSubmitting
                    ? null
                    : (value) => setState(() => _acceptedTerms = value),
                onHealthDataChanged: _isSubmitting
                    ? null
                    : (value) => setState(() => _acceptedHealthData = value),
                openDocument: _openLegalDocument,
              ),
              const SizedBox(height: AppSpacing.xl),
              FilledButton(
                onPressed:
                    _isSubmitting || !_acceptedTerms || !_acceptedHealthData
                    ? null
                    : _submit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                child: _isSubmitting
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.onPrimary,
                        ),
                      )
                    : const Text('AGREE AND CONTINUE'),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: AppSpacing.lg),
                InlineBanner(
                  message: _errorMessage!,
                  tone: InlineBannerTone.error,
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
            ],
          ),
        ),
      ),
    );
  }
}
