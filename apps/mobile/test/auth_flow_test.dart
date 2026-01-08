import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/core/auth_storage.dart';
import 'package:fitness_app/features/login_page.dart';


class FakeAuthService extends AuthService {
  FakeAuthService(this.tokens) : super(dio: Dio());

  final AuthTokens tokens;

  @override
  Future<AuthTokens> login({
    required String username,
    required String password,
  }) async {
    return tokens;
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

    await tester.enterText(find.byType(TextFormField).at(0), 'alice');
    await tester.enterText(find.byType(TextFormField).at(1), 'Password123!');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Sign in'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(loggedIn, isTrue);
    expect(await authStorage.getAccessToken(), 'access');
    expect(await authStorage.getRefreshToken(), 'refresh');
  });
}
