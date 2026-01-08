import 'package:flutter/material.dart';

import '../core/auth_service.dart';
import '../ui_components/ui_components.dart';
import '../ui_system/tokens.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({
    super.key,
    required this.authService,
  });

  final AuthService authService;

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _usernameController.dispose();
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
    });

    try {
      await widget.authService.register(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        email: _emailController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account created. Please sign in.')),
      );
      Navigator.of(context).pop();
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
        _errorMessage = 'Unable to register. Please try again.';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        title: const Text('Create account'),
      ),
      scrollable: true,
      body: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppFormField(
              controller: _usernameController,
              label: 'Username',
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.username],
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Enter a username.';
                }
                return null;
              },
            ),
            const SizedBox(height: AppSpacing.md),
            AppFormField(
              controller: _emailController,
              label: 'Email (optional)',
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email],
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return null;
                }
                if (!value.contains('@')) {
                  return 'Enter a valid email.';
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
              autofillHints: const [AutofillHints.newPassword],
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Enter a password.';
                }
                if (value.length < 8) {
                  return 'Password must be at least 8 characters.';
                }
                return null;
              },
            ),
            const SizedBox(height: AppSpacing.md),
            AppPrimaryButton(
              onPressed: _isLoading ? null : _submit,
              isLoading: _isLoading,
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
