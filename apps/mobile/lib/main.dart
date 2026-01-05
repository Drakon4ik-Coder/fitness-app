import 'package:flutter/material.dart';

import 'core/auth_service.dart';
import 'core/auth_storage.dart';
import 'features/barcode_lookup_page.dart';
import 'features/login_page.dart';

void main() {
  runApp(const FitnessApp());
}

class FitnessApp extends StatelessWidget {
  const FitnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fitness App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
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

    return BarcodeLookupPage(
      accessToken: _accessToken!,
      onLogout: _handleLogout,
    );
  }
}
