import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import 'core/auth_interceptor.dart';
import 'core/auth_service.dart';
import 'core/auth_storage.dart';
import 'features/login_page.dart';
import 'features/main_shell.dart';
import 'ui_components/ui_components.dart';
import 'ui_system/lumina_health_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FitnessApp());
}

class FitnessApp extends StatelessWidget {
  const FitnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Symbio',
      // Dark-only design system: `theme` (the light slot) is set to the dark
      // theme so the app always renders dark regardless of OS brightness.
      theme: LuminaHealthTheme.dark(),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final AuthStorage _authStorage = AuthStorage();
  final AuthService _authService = AuthService();

  bool _isLoading = true;
  String? _accessToken;
  AuthInterceptor? _authInterceptor;

  @override
  void initState() {
    super.initState();
    _loadToken();
  }

  Future<void> _loadToken() async {
    final token = await _authStorage.getAccessToken();
    if (!mounted) {
      return;
    }
    setState(() {
      _accessToken = token;
      _authInterceptor = token != null
          ? AuthInterceptor(
              storage: _authStorage,
              authService: _authService,
              onSessionExpired: _handleLogout,
              accessToken: token,
            )
          : null;
      _isLoading = false;
    });
    if (token != null) unawaited(_reportTimezone(token));
  }

  Future<void> _handleLoggedIn() async {
    final token = await _authStorage.getAccessToken();
    if (!mounted) {
      return;
    }
    setState(() {
      _accessToken = token;
      _authInterceptor = token != null
          ? AuthInterceptor(
              storage: _authStorage,
              authService: _authService,
              onSessionExpired: _handleLogout,
              accessToken: token,
            )
          : null;
    });
    if (token != null) unawaited(_reportTimezone(token));
  }

  /// Tell the backend the device's IANA timezone so it can convert UTC meal
  /// timestamps back to the user's wall clock. Best-effort and non-blocking.
  Future<void> _reportTimezone(String accessToken) async {
    try {
      final timezone = await FlutterTimezone.getLocalTimezone();
      await _authService.updateTimezone(
        accessToken: accessToken,
        timezone: timezone,
      );
    } catch (_) {
      // Non-critical; the backend keeps the last known zone (UTC by default).
    }
  }

  Future<void> _handleLogout() async {
    await _authStorage.clear();
    if (!mounted) {
      return;
    }
    setState(() {
      _accessToken = null;
      _authInterceptor = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      // Mirror the native splash (brand background + SYMBIO mark) so there is
      // no jarring flash between the OS splash and the Flutter loading state.
      final colorScheme = Theme.of(context).colorScheme;
      return Scaffold(
        backgroundColor: colorScheme.surfaceContainerLowest,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandMark(),
              const SizedBox(height: 32),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_accessToken == null) {
      return LoginPage(
        authService: _authService,
        authStorage: _authStorage,
        onLoggedIn: _handleLoggedIn,
      );
    }

    return MainShell(
      accessToken: _accessToken!,
      onLogout: _handleLogout,
      authInterceptor: _authInterceptor,
    );
  }
}
