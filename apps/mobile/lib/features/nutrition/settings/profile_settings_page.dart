import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/auth_service.dart';
import '../../../core/google_auth_service.dart';
import '../../../ui_components/ui_components.dart';
import '../../../ui_system/lumina_health_theme.dart';
import '../../../ui_system/tokens.dart';
import 'unsaved_changes_scope.dart';

/// Nested settings page for account identity: editable display name and
/// username (@handle), plus the read-only email.
///
/// Re-fetches /auth/me on open so it self-heals if the hub's startup fetch
/// failed (e.g. offline at launch). Pops with the saved [AccountInfo] so the
/// settings hub can refresh its Profile row.
class ProfileSettingsPage extends StatefulWidget {
  const ProfileSettingsPage({
    super.key,
    required this.accessToken,
    required this.authService,
    required this.initialDisplayName,
    required this.initialUsername,
    required this.email,
    required this.onAccountDeleted,
    this.googleAuthService,
  });

  final String accessToken;
  final AuthService authService;
  final String initialDisplayName;
  final String initialUsername;
  final String email;

  /// Called after the server confirms account deletion: wipes local data and
  /// signs out (provided by the shell).
  final Future<void> Function() onAccountDeleted;

  /// Re-auth for OAuth-only accounts (no password to re-enter); tests pass a
  /// fake, the real Google account picker is the default.
  final GoogleAuthService? googleAuthService;

  @override
  State<ProfileSettingsPage> createState() => _ProfileSettingsPageState();
}

class _ProfileSettingsPageState extends State<ProfileSettingsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _displayNameController;
  late final TextEditingController _usernameController;

  // Dirty is measured against these, which move if the on-open fetch brings
  // fresher values before the user starts editing.
  late String _baseDisplayName;
  late String _baseUsername;
  late String _email;

  bool _saving = false;
  bool _dirty = false;
  bool _deleting = false;
  // True until /me says otherwise, so a fetch failure degrades to the
  // password prompt (harmless for OAuth accounts: the server rejects it).
  bool _hasPassword = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _baseDisplayName = widget.initialDisplayName;
    _baseUsername = widget.initialUsername;
    _email = widget.email;
    _displayNameController = TextEditingController(text: _baseDisplayName);
    _usernameController = TextEditingController(text: _baseUsername);
    _displayNameController.addListener(_recomputeDirty);
    _usernameController.addListener(_recomputeDirty);
    _refreshAccount();
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _refreshAccount() async {
    final info = await widget.authService.fetchMe(
      accessToken: widget.accessToken,
    );
    if (!mounted || info == null) return;
    if (!_dirty) {
      _baseDisplayName = info.displayName;
      _baseUsername = info.username;
      _displayNameController.text = info.displayName;
      _usernameController.text = info.username;
    }
    setState(() {
      _email = info.email;
      _hasPassword = info.hasPassword;
    });
  }

  void _recomputeDirty() {
    final dirty =
        _displayNameController.text.trim() != _baseDisplayName.trim() ||
        _usernameController.text.trim() != _baseUsername.trim();
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    try {
      final displayName = _displayNameController.text.trim();
      final username = _usernameController.text.trim();
      await widget.authService.updateProfile(
        accessToken: widget.accessToken,
        displayName: displayName,
        username: username.isEmpty ? null : username,
        clearUsername: username.isEmpty && _baseUsername.isNotEmpty,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile saved')));
      Navigator.of(context).pop(
        AccountInfo(
          email: _email,
          displayName: displayName,
          username: username,
        ),
      );
    } on AuthException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDeleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This permanently deletes your account and everything in it — your '
          'food log, goals, preferences and custom foods. This cannot be '
          'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: LuminaHealthColors.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_hasPassword) {
      await _deleteWithPassword();
    } else {
      await _deleteWithGoogle();
    }
  }

  /// Password accounts re-prove the password in a dialog; the dialog runs the
  /// delete call itself so a wrong password can be retried in place.
  Future<void> _deleteWithPassword() async {
    final deleted = await showDialog<bool>(
      context: context,
      builder: (_) => _PasswordReauthDialog(
        deleteAccount: (password) => widget.authService.deleteAccount(
          accessToken: widget.accessToken,
          password: password,
        ),
      ),
    );
    if (deleted == true) await _finishDeletion();
  }

  /// OAuth-only accounts have no password — re-auth is a fresh Google
  /// sign-in, whose ID token the server verifies against this account.
  Future<void> _deleteWithGoogle() async {
    setState(() {
      _deleting = true;
      _errorMessage = null;
    });
    try {
      final googleAuth = widget.googleAuthService ?? GoogleAuthService();
      final idToken = await googleAuth.signInAndGetToken();
      if (idToken == null) return; // user dismissed the account picker
      await widget.authService.deleteAccount(
        accessToken: widget.accessToken,
        googleIdToken: idToken,
      );
      await _finishDeletion();
    } on AuthException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _errorMessage =
              'Could not delete the account. Please try again later.',
        );
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _finishDeletion() async {
    // Wipe + sign-out first; then unwind to the root route, because AuthGate
    // only swaps `home` (this pushed route would otherwise stay on top of the
    // login page).
    await widget.onAccountDeleted();
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return UnsavedChangesScope(
      dirty: _dirty,
      child: AppScaffold(
        safeArea: true,
        padding: EdgeInsets.zero,
        appBar: AppBar(title: const Text('Profile'), centerTitle: false),
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
                controller: _displayNameController,
                label: 'Display name',
                textInputAction: TextInputAction.next,
                validator: (raw) =>
                    (raw ?? '').trim().isEmpty ? 'Enter a display name' : null,
                bottomSpacing: AppSpacing.md,
              ),
              TextFormField(
                controller: _usernameController,
                textInputAction: TextInputAction.done,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
                  LengthLimitingTextInputFormatter(20),
                ],
                decoration: const InputDecoration(
                  labelText: 'Username',
                  prefixText: '@',
                  hintText: 'not set',
                  helperText:
                      'Your unique handle for friends and the forum. Optional.',
                  // Keep the @ prefix and hint visible while empty.
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ),
                validator: (raw) {
                  final text = (raw ?? '').trim();
                  if (text.isEmpty) return null; // optional until chosen
                  if (!RegExp(r'^[A-Za-z0-9_]{3,20}$').hasMatch(text)) {
                    return 'Use 3-20 letters, numbers or underscores';
                  }
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Email',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Flexible(
                    child: Text(
                      _email.isEmpty ? '—' : _email,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
              AppPrimaryButton(
                onPressed: _saving ? null : _save,
                isLoading: _saving,
                child: const Text('Save changes'),
              ),
              // Danger zone — kept well clear of the routine actions above,
              // mirroring the logout placement on the settings hub. Play
              // requires in-app account deletion (KAN-42).
              const SizedBox(height: AppSpacing.xxl),
              Divider(color: scheme.outlineVariant),
              const SizedBox(height: AppSpacing.md),
              TextButton.icon(
                onPressed: _deleting ? null : _confirmDeleteAccount,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete account'),
                style: TextButton.styleFrom(
                  foregroundColor: LuminaHealthColors.error,
                  minimumSize: const Size(0, 48),
                  alignment: Alignment.centerLeft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Collects the account password and runs the delete call in place, so a
/// wrong password shows an inline error and can be retried without reopening
/// the dialog. Pops true only after the server confirmed the deletion.
class _PasswordReauthDialog extends StatefulWidget {
  const _PasswordReauthDialog({required this.deleteAccount});

  final Future<void> Function(String password) deleteAccount;

  @override
  State<_PasswordReauthDialog> createState() => _PasswordReauthDialogState();
}

class _PasswordReauthDialogState extends State<_PasswordReauthDialog> {
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _passwordController.text;
    if (password.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.deleteAccount(password);
      if (mounted) Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Confirm your password'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Enter your password to permanently delete this account.'),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _passwordController,
            obscureText: true,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              errorText: _error,
              errorMaxLines: 3,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _busy ? null : _submit,
          style: TextButton.styleFrom(
            foregroundColor: LuminaHealthColors.error,
          ),
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Delete account'),
        ),
      ],
    );
  }
}
