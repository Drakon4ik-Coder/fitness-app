import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/features/forgot_password_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted password-reset outcomes, one per call.
class _FakeAuthService extends AuthService {
  _FakeAuthService(this.outcomes) : super(dio: Dio());

  final List<Object?> outcomes;
  final List<String> requested = [];

  @override
  Future<void> requestPasswordReset(String email) async {
    requested.add(email);
    final outcome = outcomes.isEmpty ? null : outcomes.removeAt(0);
    if (outcome != null) throw outcome;
  }
}

Future<void> _pump(
  WidgetTester tester,
  AuthService service, {
  String? initialEmail,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ForgotPasswordPage(
        authService: service,
        initialEmail: initialEmail,
      ),
    ),
  );
}

void main() {
  testWidgets('validates the email before calling the API', (tester) async {
    final service = _FakeAuthService([]);
    await _pump(tester, service);

    await tester.tap(find.text('SEND RESET LINK'));
    await tester.pump();
    expect(find.text('Enter your email.'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'not-an-email');
    await tester.tap(find.text('SEND RESET LINK'));
    await tester.pump();
    expect(find.text('Enter a valid email.'), findsOneWidget);
    expect(service.requested, isEmpty);
  });

  testWidgets('a sent link shows the confirmation and a resend cooldown', (
    tester,
  ) async {
    final service = _FakeAuthService([]);
    await _pump(tester, service, initialEmail: ' me@example.com ');

    await tester.tap(find.text('SEND RESET LINK'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(service.requested, ['me@example.com']);
    expect(find.text('Check your inbox'), findsOneWidget);
    expect(find.textContaining('me@example.com'), findsOneWidget);
    expect(find.text("Didn't get it? Resend in 30s"), findsOneWidget);

    // The resend button stays disabled until the 30s cooldown runs out.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text("Didn't get it? Resend in 29s"), findsOneWidget);
    await tester.pump(const Duration(seconds: 29));
    expect(find.text("Didn't get it? Resend email"), findsOneWidget);

    await tester.tap(find.text("Didn't get it? Resend email"));
    await tester.pump();
    await tester.pump();
    expect(service.requested, ['me@example.com', 'me@example.com']);
    expect(
      find.text('Reset link sent again. Check your inbox.'),
      findsOneWidget,
    );
    expect(find.text("Didn't get it? Resend in 30s"), findsOneWidget);

    // Unmounting mid-cooldown must cancel the ticker cleanly.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed resend shows its message', (tester) async {
    final service = _FakeAuthService([
      null,
      AuthException('Could not send the email. Please try again later.'),
    ]);
    await _pump(tester, service, initialEmail: 'me@example.com');
    await tester.tap(find.text('SEND RESET LINK'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));

    await tester.tap(find.text("Didn't get it? Resend email"));
    await tester.pump();
    await tester.pump();
    expect(
      find.text('Could not send the email. Please try again later.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('API and unexpected failures show an inline error', (
    tester,
  ) async {
    final service = _FakeAuthService([
      AuthException('Could not send the email. Please try again later.'),
      StateError('boom'),
    ]);
    await _pump(tester, service, initialEmail: 'me@example.com');

    await tester.tap(find.text('SEND RESET LINK'));
    await tester.pump();
    expect(
      find.text('Could not send the email. Please try again later.'),
      findsOneWidget,
    );

    await tester.tap(find.text('SEND RESET LINK'));
    await tester.pump();
    expect(
      find.text('Something went wrong. Please try again.'),
      findsOneWidget,
    );
    expect(find.text('Check your inbox'), findsNothing);
  });

  testWidgets('shows a spinner while the request is in flight', (tester) async {
    final gate = Completer<void>();
    final service = _GatedAuthService(gate.future);
    await _pump(tester, service, initialEmail: 'me@example.com');

    await tester.tap(find.text('SEND RESET LINK'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete();
    await tester.pump();
    expect(find.text('Check your inbox'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('back to login pops the page', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    ForgotPasswordPage(authService: _FakeAuthService([])),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Reset Password'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Reset Password'), findsNothing);
  });

  testWidgets('back to login from the sent stage pops too', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ForgotPasswordPage(
                  authService: _FakeAuthService([]),
                  initialEmail: 'me@example.com',
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
    await tester.tap(find.text('SEND RESET LINK'));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('BACK TO LOGIN'));
    await tester.pumpAndSettle();
    expect(find.text('Check your inbox'), findsNothing);
  });
}

class _GatedAuthService extends AuthService {
  _GatedAuthService(this.gate) : super(dio: Dio());

  final Future<void> gate;

  @override
  Future<void> requestPasswordReset(String email) => gate;
}
