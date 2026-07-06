import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/core/auth_storage.dart';
import 'package:fitness_app/features/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAuthService extends AuthService {
  FakeAuthService(this.tokens) : super(dio: Dio());

  final AuthTokens tokens;

  @override
  Future<AuthTokens> login({
    required String email,
    required String password,
  }) async {
    return tokens;
  }
}

class UnverifiedAuthService extends AuthService {
  UnverifiedAuthService() : super(dio: Dio());

  String? resentEmail;

  @override
  Future<AuthTokens> login({
    required String email,
    required String password,
  }) async {
    throw AuthException(
      'Please confirm your email before signing in.',
      emailUnverified: true,
    );
  }

  @override
  Future<void> resendVerification(String email) async {
    resentEmail = email;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Login stores tokens on success', (WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final authStorage = AuthStorage();
    final authService = FakeAuthService(
      const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
    );
    var loggedIn = false;

    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          authService: authService,
          authStorage: authStorage,
          onLoggedIn: () {
            loggedIn = true;
          },
        ),
      ),
    );

    await tester.enterText(
      find.byType(TextFormField).at(0),
      'alice@example.com',
    );
    await tester.enterText(find.byType(TextFormField).at(1), 'Password123!');
    await tester.tap(find.widgetWithText(FilledButton, 'LOGIN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(loggedIn, isTrue);
    expect(await authStorage.getAccessToken(), 'access');
    expect(await authStorage.getRefreshToken(), 'refresh');
  });

  testWidgets('Unverified login reveals resend button that resends', (
    WidgetTester tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final authService = UnverifiedAuthService();

    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          authService: authService,
          authStorage: AuthStorage(),
          onLoggedIn: () {},
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField).at(0), 'bob@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'Password123!');
    await tester.tap(find.widgetWithText(FilledButton, 'LOGIN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    // The verification error surfaces a resend action.
    final resendButton = find.widgetWithText(
      TextButton,
      'Resend verification email',
    );
    expect(resendButton, findsOneWidget);

    await tester.ensureVisible(resendButton);
    await tester.tap(resendButton);
    await tester.pump();

    expect(authService.resentEmail, 'bob@example.com');
  });
}
