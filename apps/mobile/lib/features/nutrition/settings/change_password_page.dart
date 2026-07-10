import 'package:flutter/material.dart';

import '../../../core/auth_service.dart';
import '../../../ui_components/ui_components.dart';
import '../../../ui_system/tokens.dart';
import 'unsaved_changes_scope.dart';

/// Nested settings page for changing the account password while signed in
/// (KAN-50). The server re-proves the current password before accepting the
/// new one; a wrong current password surfaces the backend's deliberately
/// vague re-auth message.
///
/// Only reachable for password accounts — the Profile page hides the entry
/// when /auth/me reports no usable password (OAuth-only accounts).
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({
    super.key,
    required this.accessToken,
    required this.authService,
  });

  final String accessToken;
  final AuthService authService;

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _saving = false;
  bool _dirty = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _currentController.addListener(_recomputeDirty);
    // The strength meter re-grades on every keystroke, not just on the
    // dirty-flag transition the other fields need.
    _newController.addListener(() {
      _recomputeDirty();
      if (mounted) setState(() {});
    });
    _confirmController.addListener(_recomputeDirty);
  }

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _recomputeDirty() {
    final dirty =
        _currentController.text.isNotEmpty ||
        _newController.text.isNotEmpty ||
        _confirmController.text.isNotEmpty;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    try {
      await widget.authService.changePassword(
        accessToken: widget.accessToken,
        currentPassword: _currentController.text,
        newPassword: _newController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Password changed')));
      Navigator.of(context).pop();
    } on AuthException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _visibilityToggle({
    required bool obscured,
    required VoidCallback onToggle,
  }) {
    return IconButton(
      tooltip: obscured ? 'Show password' : 'Hide password',
      icon: Icon(
        obscured ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onPressed: onToggle,
    );
  }

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesScope(
      dirty: _dirty,
      child: AppScaffold(
        safeArea: true,
        padding: EdgeInsets.zero,
        appBar: AppBar(
          title: const Text('Change password'),
          centerTitle: false,
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.xxl,
            ),
            children: [
              if (_errorMessage != null) ...[
                InlineBanner(
                  message: _errorMessage!,
                  tone: InlineBannerTone.error,
                ),
                const SizedBox(height: AppSpacing.lg),
              ],
              AppFormField(
                controller: _currentController,
                label: 'Current password',
                obscureText: _obscureCurrent,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.password],
                suffixIcon: _visibilityToggle(
                  obscured: _obscureCurrent,
                  onToggle: () =>
                      setState(() => _obscureCurrent = !_obscureCurrent),
                ),
                validator: (raw) =>
                    (raw ?? '').isEmpty ? 'Enter your current password.' : null,
                bottomSpacing: AppSpacing.lg,
              ),
              AppFormField(
                controller: _newController,
                label: 'New password',
                obscureText: _obscureNew,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.newPassword],
                suffixIcon: _visibilityToggle(
                  obscured: _obscureNew,
                  onToggle: () => setState(() => _obscureNew = !_obscureNew),
                ),
                validator: (raw) {
                  final value = raw ?? '';
                  if (value.isEmpty) return 'Enter a new password.';
                  if (value.length < 8) {
                    return 'Password must be at least 8 characters.';
                  }
                  return null;
                },
              ),
              PasswordStrengthMeter(password: _newController.text),
              const SizedBox(height: AppSpacing.lg),
              AppFormField(
                controller: _confirmController,
                label: 'Confirm new password',
                obscureText: _obscureConfirm,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.newPassword],
                onFieldSubmitted: (_) => _submit(),
                suffixIcon: _visibilityToggle(
                  obscured: _obscureConfirm,
                  onToggle: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                ),
                validator: (raw) => (raw ?? '') != _newController.text
                    ? 'Passwords do not match.'
                    : null,
              ),
              const SizedBox(height: AppSpacing.xl),
              AppPrimaryButton(
                onPressed: _saving ? null : _submit,
                isLoading: _saving,
                child: const Text('Change password'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
