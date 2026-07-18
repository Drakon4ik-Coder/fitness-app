import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/core/auth_storage.dart';
import 'package:fitness_app/features/forgot_password_page.dart';
import 'package:fitness_app/features/login_page.dart';
import 'package:fitness_app/features/register_page.dart';
import 'package:fitness_app/ui_components/ui_components.dart';
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

class FailingRegisterService extends AuthService {
  FailingRegisterService() : super(dio: Dio());

  @override
  Future<void> register({
    required String email,
    required String password,
    required bool acceptTerms,
    required bool acceptHealthData,
  }) async {
    throw AuthException('Unable to register with those details.');
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

  testWidgets('Login links are real buttons that navigate', (
    WidgetTester tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final authService = FakeAuthService(
      const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          authService: authService,
          authStorage: AuthStorage(),
          onLoggedIn: () {},
        ),
      ),
    );

    // Links carry button semantics (LinkButton), not bare GestureDetectors.
    final forgotLink = find.widgetWithText(LinkButton, 'FORGOT PASSWORD?');
    final registerLink = find.widgetWithText(LinkButton, 'Create account');
    expect(forgotLink, findsOneWidget);
    expect(registerLink, findsOneWidget);

    await tester.ensureVisible(registerLink);
    await tester.tap(registerLink);
    await tester.pumpAndSettle();
    expect(find.byType(RegisterPage), findsOneWidget);

    // Pop back through the register page's own footer link.
    final loginLink = find.widgetWithText(LinkButton, 'Log In');
    await tester.ensureVisible(loginLink);
    await tester.tap(loginLink);
    await tester.pumpAndSettle();
    expect(find.byType(RegisterPage), findsNothing);

    await tester.ensureVisible(forgotLink);
    await tester.tap(forgotLink);
    await tester.pumpAndSettle();
    expect(find.byType(ForgotPasswordPage), findsOneWidget);
  });

  testWidgets('Auth fields show a single label, not a doubled one', (
    WidgetTester tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});

    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          authService: FakeAuthService(
            const AuthTokens(accessToken: 'a', refreshToken: 'r'),
          ),
          authStorage: AuthStorage(),
          onLoggedIn: () {},
        ),
      ),
    );

    // The uppercase micro-labels are the only labels; the old floating
    // InputDecoration labels ('E-mail'/'Password') doubled them.
    expect(find.text('EMAIL'), findsOneWidget);
    expect(find.text('PASSWORD'), findsOneWidget);
    expect(find.text('E-mail'), findsNothing);
    expect(find.text('Password'), findsNothing);
  });

  testWidgets('Register error banner appears above the footer', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: RegisterPage(authService: FailingRegisterService())),
    );

    await tester.enterText(
      find.byType(TextFormField).at(0),
      'carol@example.com',
    );
    await tester.enterText(find.byType(TextFormField).at(1), 'Password123!');
    // Submit only enables once both consent checkboxes are ticked (KAN-103).
    await tester.ensureVisible(find.byType(Checkbox).at(0));
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'CREATE ACCOUNT'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'CREATE ACCOUNT'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    final banner = find.byType(InlineBanner);
    expect(banner, findsOneWidget);

    // The banner sits directly under the submit button, not below the
    // "Already have an account?" footer.
    final submitBottom = tester
        .getBottomLeft(find.widgetWithText(FilledButton, 'CREATE ACCOUNT'))
        .dy;
    final bannerTop = tester.getTopLeft(banner).dy;
    final footerTop = tester
        .getTopLeft(find.widgetWithText(LinkButton, 'Log In'))
        .dy;
    expect(bannerTop, greaterThan(submitBottom));
    expect(bannerTop, lessThan(footerTop));
  });
}
