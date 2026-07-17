import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/features/nutrition/data/preferences_api_service.dart';
import 'package:fitness_app/features/nutrition/data/user_preferences.dart';
import 'package:fitness_app/features/nutrition/settings/change_password_page.dart';
import 'package:fitness_app/features/nutrition/settings/focus_nutrients_settings_page.dart';
import 'package:fitness_app/features/nutrition/settings/goals_settings_page.dart';
import 'package:fitness_app/features/nutrition/settings/profile_settings_page.dart';
import 'package:fitness_app/features/nutrition/settings/units_settings_page.dart';
import 'package:fitness_app/features/nutrition/settings/warnings_settings_page.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// KAN-94: every settings form pins its primary action to the bottom of the
/// screen instead of appending it to the scrolling list, so it is tappable on
/// first build no matter how long the form is. These tests use a phone-sized
/// viewport small enough that the longer forms overflow, then assert the
/// button is hit-testable without any scrolling and no longer lives inside
/// the list.
void main() {
  // Wide enough for PasswordStrengthMeter's hint row under the test font,
  // short enough that the longer forms overflow vertically.
  void shrinkView(WidgetTester tester) {
    tester.view.physicalSize = const Size(480, 520);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  PreferencesApiService prefsApi() {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: {}),
        ),
      ),
    );
    return PreferencesApiService(accessToken: 'token', dio: dio);
  }

  AuthService authService() {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'email': 'me@example.com',
              'display_name': 'Casey',
              'username': '',
              'has_password': true,
            },
          ),
        ),
      ),
    );
    return AuthService(dio: dio);
  }

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    shrinkView(tester);
    await tester.pumpWidget(
      MaterialApp(theme: LuminaHealthTheme.dark(), home: page),
    );
    await tester.pumpAndSettle();
  }

  /// The action must be tappable immediately and live outside the list, so
  /// scrolling the form never moves it.
  void expectPinnedAction(WidgetTester tester, String label) {
    final button = find.widgetWithText(ElevatedButton, label);
    expect(button.hitTestable(), findsOneWidget);
    expect(
      find.ancestor(of: button, matching: find.byType(ListView)),
      findsNothing,
    );
  }

  /// Guards the premise: on this viewport the form really does overflow, so a
  /// list-embedded button would have required scrolling.
  void expectFormScrolls(WidgetTester tester) {
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
  }

  testWidgets('goals page save is visible without scrolling', (tester) async {
    await pumpPage(
      tester,
      GoalsSettingsPage(
        preferencesApi: prefsApi(),
        initialPreferences: const UserPreferences(),
      ),
    );
    expectFormScrolls(tester);
    expectPinnedAction(tester, 'Save changes');
  });

  testWidgets('units page save is visible without scrolling', (tester) async {
    await pumpPage(
      tester,
      UnitsSettingsPage(
        preferencesApi: prefsApi(),
        initialPreferences: const UserPreferences(),
      ),
    );
    expectPinnedAction(tester, 'Save changes');
  });

  testWidgets('warnings page save is visible without scrolling', (
    tester,
  ) async {
    await pumpPage(
      tester,
      WarningsSettingsPage(
        preferencesApi: prefsApi(),
        initialPreferences: const UserPreferences(),
      ),
    );
    expectFormScrolls(tester);
    expectPinnedAction(tester, 'Save changes');
  });

  testWidgets('focus page save is visible without scrolling', (tester) async {
    await pumpPage(
      tester,
      FocusNutrientsSettingsPage(
        preferencesApi: prefsApi(),
        initialPreferences: const UserPreferences(),
      ),
    );
    expectFormScrolls(tester);
    expectPinnedAction(tester, 'Save changes');
  });

  testWidgets('profile page save is visible without scrolling', (tester) async {
    await pumpPage(
      tester,
      ProfileSettingsPage(
        accessToken: 'token',
        authService: authService(),
        initialDisplayName: 'Casey',
        initialUsername: '',
        email: 'me@example.com',
        onAccountDeleted: () async {},
      ),
    );
    expectPinnedAction(tester, 'Save changes');
  });

  testWidgets('change-password submit is visible without scrolling', (
    tester,
  ) async {
    await pumpPage(
      tester,
      ChangePasswordPage(accessToken: 'token', authService: authService()),
    );
    expectPinnedAction(tester, 'Change password');
  });
}
