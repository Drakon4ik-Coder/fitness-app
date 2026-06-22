import 'package:flutter/material.dart';

import 'core/auth_interceptor.dart';
import 'core/auth_service.dart';
import 'core/auth_storage.dart';
import 'features/nutrition/nutrition_today_page.dart';
import 'features/login_page.dart';
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
      title: 'Fitness App',
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

    return NutritionTodayPage(
      accessToken: _accessToken!,
      onLogout: _handleLogout,
      authInterceptor: _authInterceptor,
    );
  }
}
