import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/features/nutrition/account_page.dart';
import 'package:fitness_app/features/nutrition/data/preferences_api_service.dart';
import 'package:fitness_app/features/nutrition/data/user_preferences.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';

/// A Dio whose requests are all resolved by [onRequest], for stubbing the
/// account page's network calls without hitting a server.
Dio _stubDio(void Function(RequestOptions, ResponseHandler) onRequest) {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: onRequest));
  return dio;
}

typedef ResponseHandler = RequestInterceptorHandler;

void main() {
  testWidgets('save collects goals, PATCHes prefs and pops the result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, dynamic>? patchedPrefsBody;

    final prefsDio = _stubDio((options, handler) {
      if (options.method == 'PATCH') {
        patchedPrefsBody = options.data as Map<String, dynamic>;
      }
      handler.resolve(
        Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'weight_unit': 'kg',
            'height_unit': 'cm',
            'energy_unit': 'kcal',
            'daily_calorie_goal': 2200,
            'nutrient_goals': {'protein': 100.0},
          },
        ),
      );
    });

    final authDio = _stubDio((options, handler) {
      handler.resolve(
        Response(
          requestOptions: options,
          statusCode: 200,
          data: {'email': 'me@example.com', 'display_name': 'Casey'},
        ),
      );
    });

    UserPreferences? popped;
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                popped = await Navigator.of(context).push<UserPreferences>(
                  MaterialPageRoute<UserPreferences>(
                    builder: (_) => AccountPage(
                      accessToken: 'token',
                      preferencesApi: PreferencesApiService(
                        accessToken: 'token',
                        dio: prefsDio,
                      ),
                      authService: AuthService(dio: authDio),
                      onLogout: () async {},
                      initialPreferences: const UserPreferences(
                        nutrientGoals: {'protein': 100},
                      ),
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Email loaded from /auth/me; the protein override prefilled its field.
    expect(find.text('me@example.com'), findsOneWidget);

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(patchedPrefsBody, isNotNull);
    expect(patchedPrefsBody!['nutrient_goals'], {'protein': 100.0});
    expect(patchedPrefsBody!['daily_calorie_goal'], 2200);
    // Popped with the server's snapshot so the caller can refresh.
    expect(popped, isNotNull);
    expect(popped!.nutrientGoals['protein'], closeTo(100, 1e-9));
  });

  testWidgets('reset clears goal fields back to blank', (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prefsDio = _stubDio(
      (options, handler) => handler.resolve(
        Response(requestOptions: options, statusCode: 200, data: {}),
      ),
    );
    final authDio = _stubDio(
      (options, handler) => handler.resolve(
        Response(requestOptions: options, statusCode: 200, data: {}),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: AccountPage(
          accessToken: 'token',
          preferencesApi: PreferencesApiService(
            accessToken: 'token',
            dio: prefsDio,
          ),
          authService: AuthService(dio: authDio),
          onLogout: () async {},
          initialPreferences: const UserPreferences(
            nutrientGoals: {'protein': 130},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Protein starts prefilled from the override.
    expect(find.text('130'), findsOneWidget);

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();

    expect(find.text('130'), findsNothing);
  });
}
