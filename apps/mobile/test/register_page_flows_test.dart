import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/core/legal_links.dart';
import 'package:fitness_app/features/register_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Registration outcomes beyond the consent gating (KAN-131): the blocking
// verify-email dialog, failures, and legal links that can't open.

class _ScriptedAuthService extends AuthService {
  _ScriptedAuthService({this.error}) : super(dio: Dio());

  final Object? error;
  int registrations = 0;

  @override
  Future<void> register({
    required String email,
    required String password,
    required bool acceptTerms,
    required bool acceptHealthData,
  }) async {
    registrations++;
    if (error != null) throw error!;
  }
}

Future<void> _open(
  WidgetTester tester,
  AuthService service, {
  Future<bool> Function(Uri url)? openUrl,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RegisterPage(
                authService: service,
                openUrl: openUrl ?? (_) async => true,
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _fillAndConsent(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField).at(0), 'new@example.com');
  await tester.enterText(find.byType(TextFormField).at(1), 'Password123!');
  await tester.pump();
  await tester.ensureVisible(find.byType(Checkbox).at(0));
  await tester.tap(find.byType(Checkbox).at(0));
  await tester.tap(find.byType(Checkbox).at(1));
  await tester.pump();
}

Future<void> _submit(WidgetTester tester) async {
  final button = find.widgetWithText(FilledButton, 'CREATE ACCOUNT');
  await tester.ensureVisible(button);
  await tester.tap(button);
  // Not pumpAndSettle: the button spinner keeps animating while the
  // blocking verify-email dialog is up.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('success blocks on the verify-email dialog, then returns', (
    tester,
  ) async {
    final service = _ScriptedAuthService();
    await _open(tester, service);
    await _fillAndConsent(tester);
    await _submit(tester);

    expect(service.registrations, 1);
    expect(find.text('Verify your email'), findsOneWidget);
    expect(find.textContaining('new@example.com'), findsWidgets);

    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.byType(RegisterPage), findsNothing);
  });

  testWidgets('an unexpected failure shows a generic error', (tester) async {
    await _open(tester, _ScriptedAuthService(error: StateError('boom')));
    await _fillAndConsent(tester);
    await _submit(tester);
    expect(find.text('Unable to register. Please try again.'), findsOneWidget);
    expect(find.byType(RegisterPage), findsOneWidget);
  });

  testWidgets('submitting from the password field registers', (tester) async {
    final service = _ScriptedAuthService();
    await _open(tester, service);
    await _fillAndConsent(tester);
    await tester.showKeyboard(find.byType(TextFormField).at(1));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(service.registrations, 1);
  });

  testWidgets('the eye icon reveals the password', (tester) async {
    await _open(tester, _ScriptedAuthService());
    await tester.tap(find.byIcon(Icons.visibility_off_outlined));
    await tester.pump();
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
  });

  testWidgets('a legal link that cannot open says so', (tester) async {
    var calls = 0;
    await _open(
      tester,
      _ScriptedAuthService(),
      openUrl: (_) async {
        calls++;
        if (calls == 1) return false;
        throw StateError('no browser');
      },
    );

    await tester.ensureVisible(find.text('Terms of Service'));
    await tester.tap(find.text('Terms of Service'));
    await tester.pump();
    expect(find.text('Could not open $kTermsOfServiceUrl'), findsOneWidget);

    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .removeCurrentSnackBar();
    await tester.tap(find.text('Privacy Policy'));
    await tester.pump();
    expect(find.text('Could not open $kPrivacyPolicyUrl'), findsOneWidget);
  });
}
