import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_interceptor.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/core/auth_storage.dart';
import 'package:fitness_app/features/login_page.dart';
import 'package:fitness_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// Session lifecycle in AuthGate (KAN-131): stored token -> shell, login ->
// shell, logout -> login with the tokens wiped.

/// Answers the consent gate's /me with "nothing to accept" and records the
/// timezone reports; never touches the network.
class _FakeAuthService extends AuthService {
  _FakeAuthService() : super(dio: Dio());

  @override
  Future<AccountInfo?> fetchMe({required String accessToken}) async =>
      const AccountInfo(email: 'me@example.com', displayName: 'Me');

  @override
  Future<void> updateTimezone({
    required String accessToken,
    required String timezone,
  }) async {}
}

/// Records what the gate hands the signed-in shell.
class _ShellProbe {
  String? token;
  Future<void> Function()? logout;
  AuthInterceptor? interceptor;

  Widget build(
    String accessToken,
    Future<void> Function() onLogout,
    AuthInterceptor? authInterceptor,
  ) {
    token = accessToken;
    logout = onLogout;
    interceptor = authInterceptor;
    return Text('shell:$accessToken');
  }
}

Future<void> _pump(WidgetTester tester, _ShellProbe probe) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AuthGate(
        authStorage: AuthStorage(),
        authService: _FakeAuthService(),
        shellBuilder: probe.build,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a stored session opens the shell with an interceptor', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'access_token': 'stored',
      'refresh_token': 'r',
    });
    final probe = _ShellProbe();
    await _pump(tester, probe);

    expect(find.text('shell:stored'), findsOneWidget);
    expect(probe.interceptor, isNotNull);
  });

  testWidgets('logging in swaps the login page for the shell', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final probe = _ShellProbe();
    await _pump(tester, probe);
    expect(find.byType(LoginPage), findsOneWidget);

    // The login page saves the tokens before reporting success.
    await AuthStorage().saveTokens(
      const AuthTokens(accessToken: 'fresh', refreshToken: 'r'),
    );
    tester.widget<LoginPage>(find.byType(LoginPage)).onLoggedIn();
    await tester.pumpAndSettle();

    expect(find.text('shell:fresh'), findsOneWidget);
    expect(probe.interceptor, isNotNull);
  });

  testWidgets('logging out wipes the tokens and returns to login', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'access_token': 'stored',
      'refresh_token': 'r',
    });
    final probe = _ShellProbe();
    await _pump(tester, probe);

    await probe.logout!();
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
    expect(await AuthStorage().getAccessToken(), isNull);
  });
}
