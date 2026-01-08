import 'package:flutter/material.dart';

import '../core/auth_service.dart';
import '../core/auth_storage.dart';
import '../core/environment.dart';
import 'register_page.dart';
import '../ui_components/ui_components.dart';
import '../ui_system/tokens.dart';

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
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _usernameController.dispose();
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
    });

    try {
      final tokens = await widget.authService.login(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppScaffold(
      appBar: AppBar(
        title: const Text('Sign in'),
      ),
      scrollable: true,
      body: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'API: ${EnvironmentConfig.apiBaseUrl}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppFormField(
              controller: _usernameController,
              label: 'Username',
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.username],
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Enter your username.';
                }
                return null;
              },
            ),
            const SizedBox(height: AppSpacing.md),
            AppFormField(
              controller: _passwordController,
              label: 'Password',
              obscureText: true,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              autofillHints: const [AutofillHints.password],
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Enter your password.';
                }
                return null;
              },
            ),
            const SizedBox(height: AppSpacing.md),
            AppPrimaryButton(
              onPressed: _isLoading ? null : _submit,
              isLoading: _isLoading,
              child: const Text('Sign in'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
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
              child: const Text('Create account'),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: AppSpacing.md),
              InlineBanner(
                message: _errorMessage!,
                tone: InlineBannerTone.error,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
