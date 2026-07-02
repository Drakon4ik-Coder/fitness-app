import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/auth_service.dart';
import '../../../ui_components/ui_components.dart';
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
  });

  final String accessToken;
  final AuthService authService;
  final String initialDisplayName;
  final String initialUsername;
  final String email;

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
    setState(() => _email = info.email);
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
                validator: (raw) => (raw ?? '').trim().isEmpty
                    ? 'Enter a display name'
                    : null,
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
            ],
          ),
        ),
      ),
    );
  }
}
