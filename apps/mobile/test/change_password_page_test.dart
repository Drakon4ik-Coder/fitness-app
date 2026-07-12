import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/features/nutrition/settings/change_password_page.dart';
import 'package:fitness_app/features/nutrition/settings/profile_settings_page.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stubs POST /auth/change-password: succeeds only with [acceptedCurrent],
/// anything else gets the backend's vague 403. GET /auth/me answers for the
/// profile-page entry tests.
Dio _authDio({
  String acceptedCurrent = 'current-pass',
  bool hasPassword = true,
  List<Map<String, dynamic>>? changeBodies,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path.endsWith('/auth/change-password')) {
          final body = (options.data as Map).cast<String, dynamic>();
          changeBodies?.add(body);
          if (body['current_password'] == acceptedCurrent) {
            handler.resolve(Response(requestOptions: options, statusCode: 204));
          } else {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(
                  requestOptions: options,
                  statusCode: 403,
                  data: {'detail': 'Re-authentication failed.'},
                ),
              ),
            );
          }
          return;
        }
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'email': 'me@example.com',
              'display_name': 'Casey',
              'username': '',
              'has_password': hasPassword,
            },
          ),
        );
      },
    ),
  );
  return dio;
}

/// The page is pushed over a base scaffold — as in the app — so a pop after
/// success still has a Scaffold to host the confirmation snackbar.
Widget _changePasswordApp(Dio dio) {
  return MaterialApp(
    theme: LuminaHealthTheme.dark(),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChangePasswordPage(
                  accessToken: 'token',
                  authService: AuthService(dio: dio),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openPage(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _fillFields(
  WidgetTester tester, {
  required String current,
  required String newPassword,
  required String confirm,
}) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Current password'),
    current,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'New password'),
    newPassword,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Confirm new password'),
    confirm,
  );
  await tester.pump();
}

void main() {
  testWidgets('validates the fields before hitting the server', (
    WidgetTester tester,
  ) async {
    final bodies = <Map<String, dynamic>>[];
    await tester.pumpWidget(_changePasswordApp(_authDio(changeBodies: bodies)));
    await _openPage(tester);

    // Empty submit: every field complains, nothing is sent.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Change password'));
    await tester.pump();
    expect(find.text('Enter your current password.'), findsOneWidget);
    expect(find.text('Enter a new password.'), findsOneWidget);

    // Short new password and a mismatched confirmation.
    await _fillFields(
      tester,
      current: 'current-pass',
      newPassword: 'short',
      confirm: 'different',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Change password'));
    await tester.pump();
    expect(
      find.text('Password must be at least 8 characters.'),
      findsOneWidget,
    );
    expect(find.text('Passwords do not match.'), findsOneWidget);
    expect(bodies, isEmpty);
  });

  testWidgets('wrong current password surfaces the vague server message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_changePasswordApp(_authDio()));
    await _openPage(tester);

    await _fillFields(
      tester,
      current: 'not-my-password',
      newPassword: 'brand-new-pass-1',
      confirm: 'brand-new-pass-1',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Change password'));
    await tester.pumpAndSettle();

    expect(find.text('Re-authentication failed.'), findsOneWidget);
    // Still on the page, free to retry in place.
    expect(find.byType(ChangePasswordPage), findsOneWidget);
  });

  testWidgets('successful change pops the page and confirms', (
    WidgetTester tester,
  ) async {
    final bodies = <Map<String, dynamic>>[];
    await tester.pumpWidget(_changePasswordApp(_authDio(changeBodies: bodies)));
    await _openPage(tester);

    await _fillFields(
      tester,
      current: 'current-pass',
      newPassword: 'brand-new-pass-1',
      confirm: 'brand-new-pass-1',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Change password'));
    await tester.pumpAndSettle();

    expect(bodies, [
      {'current_password': 'current-pass', 'new_password': 'brand-new-pass-1'},
    ]);
    expect(find.byType(ChangePasswordPage), findsNothing);
    expect(find.text('Password changed'), findsOneWidget);
  });

  testWidgets('profile page offers Change password only to password accounts', (
    WidgetTester tester,
  ) async {
    Widget profileApp({required bool hasPassword}) {
      return MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: ProfileSettingsPage(
          key: ValueKey(hasPassword),
          accessToken: 'token',
          authService: AuthService(dio: _authDio(hasPassword: hasPassword)),
          initialDisplayName: 'Casey',
          initialUsername: '',
          email: 'me@example.com',
          onAccountDeleted: () async {},
        ),
      );
    }

    await tester.pumpWidget(profileApp(hasPassword: false));
    await tester.pumpAndSettle();
    expect(find.text('Change password'), findsNothing);

    await tester.pumpWidget(profileApp(hasPassword: true));
    await tester.pumpAndSettle();
    expect(find.text('Change password'), findsOneWidget);

    await tester.tap(find.text('Change password'));
    await tester.pumpAndSettle();
    expect(find.byType(ChangePasswordPage), findsOneWidget);
  });
}
