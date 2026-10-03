import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/core/auth_storage.dart';
import 'package:fitness_app/core/google_auth_service.dart';
import 'package:fitness_app/features/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// Failure and Google sign-in branches of the login page (KAN-131); the happy
// path and unverified-resend flow live in auth_flow_test.dart.

class _ScriptedAuthService extends AuthService {
  _ScriptedAuthService({this.loginError, this.googleError, this.resendError})
    : super(dio: Dio());

  final Object? loginError;
  final Object? googleError;
  final Object? resendError;
  final List<String> googleTokens = [];

  @override
  Future<AuthTokens> login({
    required String email,
    required String password,
  }) async {
    if (loginError != null) throw loginError!;
    return const AuthTokens(accessToken: 'a', refreshToken: 'r');
  }

  @override
  Future<AuthTokens> googleLogin(String idToken) async {
    googleTokens.add(idToken);
    if (googleError != null) throw googleError!;
    return const AuthTokens(accessToken: 'ga', refreshToken: 'gr');
  }

  @override
  Future<void> resendVerification(String email) async {
    if (resendError != null) throw resendError!;
  }
}

/// Google account picker stand-in: [outcome] is the id token, null for a
/// dismissed picker, or an error to throw.
class _FakeGoogleAuth extends GoogleAuthService {
  _FakeGoogleAuth(this.outcome);

  final Object? outcome;

  @override
  Future<String?> signInAndGetToken() async {
    final value = outcome;
    if (value is String?) return value;
    throw value;
  }
}

Future<AuthStorage> _pump(
  WidgetTester tester,
  AuthService service, {
  GoogleAuthService? googleAuth,
  VoidCallback? onLoggedIn,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  final storage = AuthStorage();
  await tester.pumpWidget(
    MaterialApp(
      home: LoginPage(
        authService: service,
        authStorage: storage,
        onLoggedIn: onLoggedIn ?? () {},
        googleAuth: googleAuth,
      ),
    ),
  );
  return storage;
}

Future<void> _login(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField).at(0), 'a@example.com');
  await tester.enterText(find.byType(TextFormField).at(1), 'Password123!');
  await tester.tap(find.widgetWithText(FilledButton, 'LOGIN'));
  await tester.pump();
  await tester.pump();
}

Future<void> _tapGoogle(WidgetTester tester) async {
  final button = find.bySemanticsLabel('Continue with Google');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('an unexpected login failure shows a generic error', (
    tester,
  ) async {
    await _pump(tester, _ScriptedAuthService(loginError: StateError('boom')));
    await _login(tester);
    expect(find.text('Unable to sign in. Please try again.'), findsOneWidget);
  });

  testWidgets('submitting from the password field logs in', (tester) async {
    var loggedIn = false;
    await _pump(
      tester,
      _ScriptedAuthService(),
      onLoggedIn: () => loggedIn = true,
    );
    await tester.enterText(find.byType(TextFormField).at(0), 'a@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'Password123!');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump();
    expect(loggedIn, isTrue);
  });

  testWidgets('the eye icon toggles password visibility', (tester) async {
    await _pump(tester, _ScriptedAuthService());
    bool obscured() => tester
        .widget<EditableText>(
          find.descendant(
            of: find.byType(TextFormField).at(1),
            matching: find.byType(EditableText),
          ),
        )
        .obscureText;

    expect(obscured(), isTrue);
    await tester.tap(find.byIcon(Icons.visibility_off_outlined));
    await tester.pump();
    expect(obscured(), isFalse);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
  });

  testWidgets('a failed verification resend shows its message', (tester) async {
    await _pump(
      tester,
      _ScriptedAuthService(
        loginError: AuthException('Confirm your email.', emailUnverified: true),
        resendError: AuthException('Too many requests.'),
      ),
    );
    await _login(tester);
    final resend = find.widgetWithText(TextButton, 'Resend verification email');
    await tester.ensureVisible(resend);
    await tester.tap(resend);
    await tester.pump();
    await tester.pump();
    expect(find.text('Too many requests.'), findsOneWidget);
  });

  testWidgets('resend needs an email to send to', (tester) async {
    await _pump(
      tester,
      _ScriptedAuthService(
        loginError: AuthException('Confirm your email.', emailUnverified: true),
      ),
    );
    await _login(tester);
    await tester.enterText(find.byType(TextFormField).at(0), '');
    final resend = find.widgetWithText(TextButton, 'Resend verification email');
    await tester.ensureVisible(resend);
    await tester.tap(resend);
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
  });

  group('Google sign-in', () {
    testWidgets('stores the exchanged tokens and logs in', (tester) async {
      var loggedIn = false;
      final service = _ScriptedAuthService();
      final storage = await _pump(
        tester,
        service,
        googleAuth: _FakeGoogleAuth('id-token'),
        onLoggedIn: () => loggedIn = true,
      );
      await _tapGoogle(tester);

      expect(service.googleTokens, ['id-token']);
      expect(loggedIn, isTrue);
      expect(await storage.getAccessToken(), 'ga');
    });

    testWidgets('a dismissed picker is not an error', (tester) async {
      final service = _ScriptedAuthService();
      await _pump(tester, service, googleAuth: _FakeGoogleAuth(null));
      await _tapGoogle(tester);

      expect(service.googleTokens, isEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a rejected token shows the server message', (tester) async {
      await _pump(
        tester,
        _ScriptedAuthService(
          googleError: AuthException('Google sign-in failed.'),
        ),
        googleAuth: _FakeGoogleAuth('id-token'),
      );
      await _tapGoogle(tester);
      expect(find.text('Google sign-in failed.'), findsOneWidget);
    });

    testWidgets('a picker crash shows a generic error', (tester) async {
      await _pump(
        tester,
        _ScriptedAuthService(),
        googleAuth: _FakeGoogleAuth(StateError('plugin missing')),
      );
      await _tapGoogle(tester);
      expect(find.text('Unable to sign in with Google.'), findsOneWidget);
    });
  });
}
