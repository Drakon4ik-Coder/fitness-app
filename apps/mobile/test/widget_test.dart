// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:fitness_app/core/version_check_service.dart';
import 'package:fitness_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Keeps FitnessApp tests off the network: the real service would probe
/// /health/ for the forced-update gate. 0 = gate disabled.
class _FakeVersionCheckService implements VersionCheckService {
  @override
  Future<int> fetchMinSupportedBuild() async => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Shows sign-in when no token is stored', (
    WidgetTester tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});

    await tester.pumpWidget(
      FitnessApp(versionService: _FakeVersionCheckService()),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'LOGIN'), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
  });

  testWidgets('Shows nutrition today when token exists', (
    WidgetTester tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'token'});

    await tester.pumpWidget(
      FitnessApp(versionService: _FakeVersionCheckService()),
    );
    await tester.pumpAndSettle();

    expect(find.text('EATEN'), findsOneWidget);
    // No activity source is configured, so the BURNED stat is hidden (KAN-37).
    expect(find.text('BURNED'), findsNothing);
  });
}
