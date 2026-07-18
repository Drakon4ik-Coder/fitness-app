import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/core/legal_links.dart';
import 'package:fitness_app/features/register_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingAuthService extends AuthService {
  _RecordingAuthService() : super(dio: Dio());

  Map<String, Object?>? lastRegister;

  @override
  Future<void> register({
    required String email,
    required String password,
    required bool acceptTerms,
    required bool acceptHealthData,
  }) async {
    lastRegister = {
      'email': email,
      'accept_terms': acceptTerms,
      'accept_health_data': acceptHealthData,
    };
  }
}

Future<void> _pumpRegisterPage(
  WidgetTester tester, {
  required AuthService service,
  Future<bool> Function(Uri url)? openUrl,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: RegisterPage(
        authService: service,
        openUrl: openUrl ?? (_) async => true,
      ),
    ),
  );
}

Future<void> _fillCredentials(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField).at(0), 'new@example.com');
  await tester.enterText(find.byType(TextFormField).at(1), 'Password123!');
  await tester.pump();
}

Finder get _submitButton => find.widgetWithText(FilledButton, 'CREATE ACCOUNT');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('submit stays disabled until both consents are ticked', (
    tester,
  ) async {
    await _pumpRegisterPage(tester, service: _RecordingAuthService());
    await _fillCredentials(tester);

    expect(tester.widget<FilledButton>(_submitButton).onPressed, isNull);

    await tester.ensureVisible(find.byType(Checkbox).at(0));
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    expect(tester.widget<FilledButton>(_submitButton).onPressed, isNull);

    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    expect(tester.widget<FilledButton>(_submitButton).onPressed, isNotNull);
  });

  testWidgets('registering sends both consent flags', (tester) async {
    final service = _RecordingAuthService();
    await _pumpRegisterPage(tester, service: service);
    await _fillCredentials(tester);

    await tester.ensureVisible(find.byType(Checkbox).at(0));
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    await tester.ensureVisible(_submitButton);
    await tester.tap(_submitButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(service.lastRegister, {
      'email': 'new@example.com',
      'accept_terms': true,
      'accept_health_data': true,
    });
  });

  testWidgets('consent links open the terms and privacy documents', (
    tester,
  ) async {
    final opened = <Uri>[];
    await _pumpRegisterPage(
      tester,
      service: _RecordingAuthService(),
      openUrl: (url) async {
        opened.add(url);
        return true;
      },
    );

    await tester.ensureVisible(find.text('Terms of Service'));
    await tester.tap(find.text('Terms of Service'));
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();

    expect(opened, [
      Uri.parse(kTermsOfServiceUrl),
      Uri.parse(kPrivacyPolicyUrl),
    ]);
  });
}
