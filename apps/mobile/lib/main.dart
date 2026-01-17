import 'package:flutter/material.dart';

import 'core/auth_service.dart';
import 'core/auth_storage.dart';
import 'features/nutrition/nutrition_today_page.dart';
import 'features/login_page.dart';
import 'ui_system/app_theme.dart';
import 'ui_system/pulse_theme.dart';
import 'ui_system/theme_mode_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FitnessApp());
}

class FitnessApp extends StatefulWidget {
  const FitnessApp({super.key});

  @override
  State<FitnessApp> createState() => _FitnessAppState();
}

class _FitnessAppState extends State<FitnessApp> {
  late final ThemeModeController _themeModeController =
      ThemeModeController(initialMode: ThemeMode.light);

  @override
  void dispose() {
    _themeModeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ThemeModeScope(
      controller: _themeModeController,
      child: AnimatedBuilder(
        animation: _themeModeController,
        builder: (context, _) {
          return MaterialApp(
            title: 'Fitness App',
            theme: AppTheme.light(),
            darkTheme: PulseTheme.dark(),
            themeMode: _themeModeController.mode,
            home: const AuthGate(),
          );
        },
      ),
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
    });
  }

  Future<void> _handleLogout() async {
    await _authStorage.clear();
    if (!mounted) {
      return;
    }
    setState(() {
      _accessToken = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
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
    );
  }
}
