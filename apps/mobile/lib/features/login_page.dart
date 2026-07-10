import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/auth_service.dart';
import '../core/auth_storage.dart';
import '../core/google_auth_service.dart';
import '../ui_components/ui_components.dart';
import '../ui_system/tokens.dart';
import 'forgot_password_page.dart';
import 'register_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.authService,
    required this.authStorage,
    required this.onLoggedIn,
  });

  final AuthService authService;
  final AuthStorage authStorage;
  final VoidCallback onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final GoogleAuthService _googleAuth = GoogleAuthService();

  bool _isLoading = false;
  bool _isResending = false;
  bool _obscurePassword = true;
  String? _errorMessage;
  bool _showResend = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
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
      _showResend = false;
    });

    try {
      final tokens = await widget.authService.login(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      TextInput.finishAutofillContext();
      await widget.authStorage.saveTokens(tokens);
      if (!mounted) {
        return;
      }
      widget.onLoggedIn();
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.message;
        _showResend = error.emailUnverified;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Unable to sign in. Please try again.';
        _isLoading = false;
      });
    }
  }

  Future<void> _resendVerification() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      return;
    }

    setState(() => _isResending = true);
    try {
      await widget.authService.resendVerification(email);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Verification email sent. Check your inbox.'),
        ),
      );
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) {
        setState(() => _isResending = false);
      }
    }
  }

  Future<void> _googleSubmit() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _showResend = false;
    });
    try {
      final idToken = await _googleAuth.signInAndGetToken();
      if (idToken == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      final tokens = await widget.authService.googleLogin(idToken);
      await widget.authStorage.saveTokens(tokens);
      if (!mounted) return;
      widget.onLoggedIn();
    } on AuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.message;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to sign in with Google.';
        _isLoading = false;
      });
    }
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
          // Fill the viewport and let the content center itself. The scroll
          // view only engages as a safety net when the keyboard is open, the
          // device is short, or Dynamic Type is enlarged.
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
                    child: Form(
                      key: _formKey,
                      child: AutofillGroup(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Spacer(),

                            // Brand header
                            const Center(child: BrandMark()),
                            const SizedBox(height: AppSpacing.sm),
                            Center(
                              child: Text(
                                'SYMBIO',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: colorScheme.primary,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 4,
                                ),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xl),

                            // Title
                            Text(
                              'Welcome Back',
                              style: theme.textTheme.headlineLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),

                            // Subtitle
                            Text(
                              'Continue your high-performance biometric journey.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xl),

                            // Email label
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
                              textInputAction: TextInputAction.next,
                              autofillHints: const [AutofillHints.email],
                              // The uppercase micro-label above the field is
                              // the visible label; a labelText here would
                              // render a second, floating one (KAN-58).
                              decoration: InputDecoration(
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
                            const SizedBox(height: AppSpacing.lg),

                            // Password label row with forgot password
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'PASSWORD',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                    letterSpacing: 1.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                LinkButton(
                                  label: 'FORGOT PASSWORD?',
                                  textStyle: theme.textTheme.labelSmall
                                      ?.copyWith(
                                        letterSpacing: 1,
                                        fontWeight: FontWeight.w600,
                                      ),
                                  onPressed: _isLoading
                                      ? null
                                      : () {
                                          Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  ForgotPasswordPage(
                                                    authService:
                                                        widget.authService,
                                                    initialEmail:
                                                        _emailController.text
                                                            .trim(),
                                                  ),
                                            ),
                                          );
                                        },
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            TextFormField(
                              controller: _passwordController,
                              obscureText: _obscurePassword,
                              textInputAction: TextInputAction.done,
                              onFieldSubmitted: (_) => _submit(),
                              autofillHints: const [AutofillHints.password],
                              decoration: InputDecoration(
                                hintText: 'Enter your password',
                                prefixIcon: Icon(
                                  Icons.lock_outline,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _obscurePassword = !_obscurePassword;
                                    });
                                  },
                                ),
                              ),
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return 'Enter your password.';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: AppSpacing.xl),

                            // Login button
                            FilledButton(
                              onPressed: _isLoading ? null : _submit,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(52),
                                backgroundColor: colorScheme.primary,
                                foregroundColor: colorScheme.onPrimary,
                                elevation: 8,
                                shadowColor: colorScheme.primary.withValues(
                                  alpha: 0.5,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.md,
                                  ),
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
                                  : const Text('LOGIN'),
                            ),

                            // Error feedback shown directly below the action that
                            // triggered it, so it stays visible without scrolling.
                            if (_errorMessage != null) ...[
                              const SizedBox(height: AppSpacing.lg),
                              InlineBanner(
                                message: _errorMessage!,
                                tone: InlineBannerTone.error,
                              ),
                              if (_showResend) ...[
                                const SizedBox(height: AppSpacing.sm),
                                TextButton(
                                  onPressed: _isResending
                                      ? null
                                      : _resendVerification,
                                  child: _isResending
                                      ? SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: colorScheme.primary,
                                          ),
                                        )
                                      : const Text('Resend verification email'),
                                ),
                              ],
                            ],
                            const SizedBox(height: AppSpacing.xl),

                            // Divider with "OR CONTINUE WITH"
                            Row(
                              children: [
                                Expanded(
                                  child: Divider(
                                    color: colorScheme.outline.withValues(
                                      alpha: 0.4,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.md,
                                  ),
                                  child: Text(
                                    'OR CONTINUE WITH',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Divider(
                                    color: colorScheme.outline.withValues(
                                      alpha: 0.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.lg),

                            // Social sign-in providers (more can be added beside Google)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SocialAuthButton(
                                  semanticLabel: 'Continue with Google',
                                  onPressed: _isLoading ? null : _googleSubmit,
                                  child: SvgPicture.asset(
                                    'assets/brand/google_g.svg',
                                    width: 24,
                                    height: 24,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.xl),

                            // Footer: New to Symbio?
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'New to Symbio? ',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                LinkButton(
                                  label: 'Create account',
                                  onPressed: _isLoading
                                      ? null
                                      : () {
                                          Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) => RegisterPage(
                                                authService: widget.authService,
                                              ),
                                            ),
                                          );
                                        },
                                ),
                              ],
                            ),

                            const Spacer(),
                          ],
                        ),
                      ),
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
}
