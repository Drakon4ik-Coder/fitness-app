import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/core/legal_links.dart';
import 'package:fitness_app/core/policy_consent_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAuthService extends AuthService {
  _FakeAuthService({this.me, this.acceptError}) : super(dio: Dio());

  /// What fetchMe returns; null simulates any failure (offline, stale token).
  AccountInfo? me;

  Object? acceptError;
  int fetchCalls = 0;
  int acceptCalls = 0;

  @override
  Future<AccountInfo?> fetchMe({required String accessToken}) async {
    fetchCalls++;
    return me;
  }

  @override
  Future<void> acceptPolicy({required String accessToken}) async {
    acceptCalls++;
    final error = acceptError;
    if (error != null) throw error;
    final current = me?.currentPolicyVersion ?? '';
    me = _info(accepted: current, current: current);
  }
}

AccountInfo _info({String accepted = '', String current = '2026-07-18'}) =>
    AccountInfo(
      email: 'user@example.com',
      displayName: 'User',
      acceptedPolicyVersion: accepted,
      currentPolicyVersion: current,
    );

Future<void> _pumpGate(
  WidgetTester tester, {
  required AuthService service,
  Future<bool> Function(Uri url)? openUrl,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PolicyConsentGate(
        accessToken: 'token',
        authService: service,
        openUrl: openUrl ?? (_) async => true,
        child: const Scaffold(body: Text('app content')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tickBothBoxes(WidgetTester tester) async {
  await tester.tap(find.byType(Checkbox).at(0));
  await tester.tap(find.byType(Checkbox).at(1));
  await tester.pump();
}

Finder get _acceptButton =>
    find.widgetWithText(FilledButton, 'AGREE AND CONTINUE');

void main() {
  testWidgets('blocks with the consent page when versions differ', (
    tester,
  ) async {
    await _pumpGate(tester, service: _FakeAuthService(me: _info()));

    expect(find.text('Before you continue'), findsOneWidget);
    expect(find.text('app content'), findsNothing);
  });

  testWidgets('passes through when the accepted version is current', (
    tester,
  ) async {
    await _pumpGate(
      tester,
      service: _FakeAuthService(me: _info(accepted: '2026-07-18')),
    );

    expect(find.text('app content'), findsOneWidget);
    expect(find.text('Before you continue'), findsNothing);
  });

  testWidgets('fails open when /auth/me is unreachable', (tester) async {
    // Offline-first: a network failure must never lock the user out — the
    // server still refuses gated writes and the outbox replays later.
    await _pumpGate(tester, service: _FakeAuthService(me: null));

    expect(find.text('app content'), findsOneWidget);
  });

  testWidgets('fails open when the backend predates policy versions', (
    tester,
  ) async {
    await _pumpGate(
      tester,
      service: _FakeAuthService(me: _info(current: '')),
    );

    expect(find.text('app content'), findsOneWidget);
  });

  testWidgets('accept stays disabled until both boxes are ticked', (
    tester,
  ) async {
    await _pumpGate(tester, service: _FakeAuthService(me: _info()));
    expect(tester.widget<FilledButton>(_acceptButton).onPressed, isNull);

    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    expect(tester.widget<FilledButton>(_acceptButton).onPressed, isNull);

    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    expect(tester.widget<FilledButton>(_acceptButton).onPressed, isNotNull);
  });

  testWidgets('accepting posts the consent and unblocks the app', (
    tester,
  ) async {
    final service = _FakeAuthService(me: _info());
    await _pumpGate(tester, service: service);

    await _tickBothBoxes(tester);
    await tester.tap(_acceptButton);
    await tester.pumpAndSettle();

    expect(service.acceptCalls, 1);
    expect(find.text('app content'), findsOneWidget);
    expect(find.text('Before you continue'), findsNothing);
  });

  testWidgets('a failed accept shows the error and stays blocked', (
    tester,
  ) async {
    final service = _FakeAuthService(
      me: _info(),
      acceptError: AuthException('Could not save your consent.'),
    );
    await _pumpGate(tester, service: service);

    await _tickBothBoxes(tester);
    await tester.tap(_acceptButton);
    await tester.pumpAndSettle();

    expect(service.acceptCalls, 1);
    expect(find.text('Could not save your consent.'), findsOneWidget);
    expect(find.text('Before you continue'), findsOneWidget);
    // The button re-enables so the user can retry.
    expect(tester.widget<FilledButton>(_acceptButton).onPressed, isNotNull);
  });

  testWidgets('links open the terms and privacy documents', (tester) async {
    final opened = <Uri>[];
    await _pumpGate(
      tester,
      service: _FakeAuthService(me: _info()),
      openUrl: (url) async {
        opened.add(url);
        return true;
      },
    );

    await tester.tap(find.text('Terms of Service'));
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();

    expect(opened, [
      Uri.parse(kTermsOfServiceUrl),
      Uri.parse(kPrivacyPolicyUrl),
    ]);
  });

  testWidgets('re-checks on app resume and blocks after a policy bump', (
    tester,
  ) async {
    final service = _FakeAuthService(me: _info(accepted: '2026-07-18'));
    await _pumpGate(tester, service: service);
    expect(find.text('app content'), findsOneWidget);

    // The server bumps POLICY_VERSION mid-session; the next resume re-check
    // must surface the consent screen.
    service.me = _info(accepted: '2026-07-18', current: '2027-01-01');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(service.fetchCalls, greaterThan(1));
    expect(find.text('Before you continue'), findsOneWidget);
  });
}
