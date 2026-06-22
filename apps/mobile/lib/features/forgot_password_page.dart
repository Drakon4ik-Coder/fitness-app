import 'dart:async';

import 'package:flutter/material.dart';

import '../core/auth_service.dart';
import '../ui_components/ui_components.dart';
import '../ui_system/tokens.dart';

/// Lets a signed-out user request a password-reset link.
///
/// The screen has two states that swap in place (rather than pushing extra
/// routes), mirroring the inline feedback model used on the login page:
///   1. [_Stage.request] — enter an email and submit.
///   2. [_Stage.sent] — a confirmation that the link is on its way.
///
/// For privacy the backend never reveals whether an account exists, so a
/// successful request always lands on the confirmation state regardless of
/// whether the address is registered.
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({
    super.key,
    required this.authService,
    this.initialEmail,
  });

  final AuthService authService;

  /// Pre-fills the field with whatever the user already typed on login.
  final String? initialEmail;

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

enum _Stage { request, sent }

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _emailController =
      TextEditingController(text: widget.initialEmail ?? '');

  _Stage _stage = _Stage.request;
  bool _isLoading = false;
  String? _errorMessage;
  String _sentToEmail = '';

  // Resend cooldown so the user can't hammer the endpoint.
  static const int _cooldownSeconds = 30;
  int _cooldownRemaining = 0;
  Timer? _cooldownTimer;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final email = _emailController.text.trim();
    try {
      await widget.authService.requestPasswordReset(email);
      if (!mounted) {
        return;
      }
      setState(() {
        _stage = _Stage.sent;
        _sentToEmail = email;
        _isLoading = false;
      });
      _startCooldown();
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.message;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Something went wrong. Please try again.';
        _isLoading = false;
      });
    }
  }

  Future<void> _resend() async {
    if (_cooldownRemaining > 0 || _isLoading) {
      return;
    }
    setState(() => _isLoading = true);
    try {
      await widget.authService.requestPasswordReset(_sentToEmail);
      if (!mounted) {
        return;
      }
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reset link sent again. Check your inbox.')),
      );
      _startCooldown();
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    }
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldownRemaining = _cooldownSeconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _cooldownRemaining--;
        if (_cooldownRemaining <= 0) {
          timer.cancel();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest,
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.2),
            radius: 1.0,
            colors: [
              colorScheme.primary.withValues(alpha: 0.15),
              Colors.transparent,
            ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                  vertical: AppSpacing.lg,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - AppSpacing.lg * 2,
                  ),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Back affordance — this is a pushed sub-screen.
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Icons.arrow_back),
                            color: colorScheme.onSurface,
                            tooltip: 'Back',
                          ),
                        ),
                        const Spacer(),
                        if (_stage == _Stage.request)
                          _buildRequest(theme, colorScheme)
                        else
                          _buildSent(theme, colorScheme),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildRequest(ThemeData theme, ColorScheme colorScheme) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: BrandMark()),
          const SizedBox(height: AppSpacing.xl),

          Text(
            'Reset Password',
            style: theme.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            "Enter your email and we'll send you a link to reset your password.",
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),

          Text(
            'EMAIL',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.email],
            onFieldSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'E-mail',
              hintText: 'Enter your e-mail',
              prefixIcon: Icon(
                Icons.alternate_email,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Enter your email.';
              }
              if (!value.contains('@')) {
                return 'Enter a valid email.';
              }
              return null;
            },
          ),
          const SizedBox(height: AppSpacing.xl),

          FilledButton(
            onPressed: _isLoading ? null : _submit,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              elevation: 8,
              shadowColor: colorScheme.primary.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              textStyle: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
              ),
            ),
            child: _isLoading
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.onPrimary,
                    ),
                  )
                : const Text('SEND RESET LINK'),
          ),

          if (_errorMessage != null) ...[
            const SizedBox(height: AppSpacing.lg),
            InlineBanner(
              message: _errorMessage!,
              tone: InlineBannerTone.error,
            ),
          ],
          const SizedBox(height: AppSpacing.xl),

          _backToLogin(theme, colorScheme),
        ],
      ),
    );
  }

  Widget _buildSent(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Glowing envelope echoing the BrandMark badge treatment.
        Center(
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colorScheme.surfaceContainerLowest,
              border: Border.all(color: colorScheme.primary, width: 2),
              boxShadow: [
                BoxShadow(
                  color: colorScheme.primary.withValues(alpha: 0.5),
                  blurRadius: 24,
                ),
              ],
            ),
            child: Icon(
              Icons.mark_email_read_outlined,
              size: 40,
              color: colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),

        Text(
          'Check your inbox',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text.rich(
          TextSpan(
            text: 'If an account exists for ',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            children: [
              TextSpan(
                text: _sentToEmail,
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const TextSpan(
                text: ", we've sent a link to reset your password.",
              ),
            ],
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xl),

        FilledButton(
          onPressed: () => Navigator.of(context).maybePop(),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            elevation: 8,
            shadowColor: colorScheme.primary.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            textStyle: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
          child: const Text('BACK TO LOGIN'),
        ),
        const SizedBox(height: AppSpacing.lg),

        // Resend with cooldown so the email can't be spammed.
        Center(
          child: TextButton(
            onPressed: (_cooldownRemaining > 0 || _isLoading) ? null : _resend,
            child: _isLoading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.primary,
                    ),
                  )
                : Text(
                    _cooldownRemaining > 0
                        ? "Didn't get it? Resend in ${_cooldownRemaining}s"
                        : "Didn't get it? Resend email",
                  ),
          ),
        ),
      ],
    );
  }

  Widget _backToLogin(ThemeData theme, ColorScheme colorScheme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Remembered it? ',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        GestureDetector(
          onTap: () => Navigator.of(context).maybePop(),
          child: Text(
            'Back to login',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
