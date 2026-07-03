import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/features/nutrition/account_page.dart';
import 'package:fitness_app/features/nutrition/data/preferences_api_service.dart';
import 'package:fitness_app/features/nutrition/data/user_preferences.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';

/// A Dio whose requests are all resolved by [onRequest], for stubbing the
/// settings pages' network calls without hitting a server.
Dio _stubDio(void Function(RequestOptions, ResponseHandler) onRequest) {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: onRequest));
  return dio;
}

typedef ResponseHandler = RequestInterceptorHandler;

void main() {
  void enlargeView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Dio authStub() => _stubDio(
    (options, handler) => handler.resolve(
      Response(
        requestOptions: options,
        statusCode: 200,
        data: {'email': 'me@example.com', 'display_name': 'Casey'},
      ),
    ),
  );

  testWidgets('goals page save PATCHes prefs and pops back through the hub', (
    tester,
  ) async {
    enlargeView(tester);

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
                      authService: AuthService(dio: authStub()),
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

    // Hub: nested rows plus the email loaded from /auth/me in a summary.
    expect(find.text('Units'), findsOneWidget);
    expect(find.text('Daily goals'), findsOneWidget);
    expect(find.textContaining('me@example.com'), findsOneWidget);

    await tester.tap(find.text('Daily goals'));
    await tester.pumpAndSettle();

    // The protein override prefilled its field on the goals page.
    expect(find.text('100'), findsOneWidget);

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(patchedPrefsBody, isNotNull);
    expect(patchedPrefsBody!['nutrient_goals'], {'protein': 100.0});
    expect(patchedPrefsBody!['daily_calorie_goal'], 2200);
    // Units weren't touched, so the partial PATCH must not include them.
    expect(patchedPrefsBody!.containsKey('weight_unit'), isFalse);
    // As a pushed route (onSaved null) the hub pops with the server snapshot.
    expect(popped, isNotNull);
    expect(popped!.nutrientGoals['protein'], closeTo(100, 1e-9));
  });

  testWidgets('units page save PATCHes only unit fields and updates the hub', (
    tester,
  ) async {
    enlargeView(tester);

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
            'weight_unit': 'lb',
            'height_unit': 'cm',
            'energy_unit': 'kcal',
          },
        ),
      );
    });

    UserPreferences? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: AccountPage(
          accessToken: 'token',
          preferencesApi: PreferencesApiService(
            accessToken: 'token',
            dio: prefsDio,
          ),
          authService: AuthService(dio: authStub()),
          onLogout: () async {},
          initialPreferences: const UserPreferences(),
          onSaved: (prefs) => saved = prefs,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Units'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('lb'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(patchedPrefsBody, isNotNull);
    expect(patchedPrefsBody!['weight_unit'], 'lb');
    expect(patchedPrefsBody!.containsKey('nutrient_goals'), isFalse);
    expect(patchedPrefsBody!.containsKey('daily_calorie_goal'), isFalse);
    expect(saved?.weightUnit, 'lb');
    // Back on the hub (as a tab it stays put), with the summary refreshed.
    expect(find.text('Daily goals'), findsOneWidget);
    expect(find.textContaining('lb'), findsWidgets);
  });

  testWidgets('reset clears goal fields back to blank', (tester) async {
    enlargeView(tester);

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

    await tester.tap(find.text('Daily goals'));
    await tester.pumpAndSettle();

    // Protein starts prefilled from the override.
    expect(find.text('130'), findsOneWidget);

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();

    expect(find.text('130'), findsNothing);
  });

  testWidgets('profile page saves display name and username', (tester) async {
    enlargeView(tester);

    Map<String, dynamic>? patchedMeBody;

    final authDio = _stubDio((options, handler) {
      if (options.method == 'PATCH') {
        patchedMeBody = Map<String, dynamic>.from(options.data as Map);
      }
      handler.resolve(
        Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'email': 'me@example.com',
            'display_name': 'Casey',
            'username': null,
          },
        ),
      );
    });
    final prefsDio = _stubDio(
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
          initialPreferences: const UserPreferences(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    // Fetched fresh on open: email row and prefilled display name.
    expect(find.text('me@example.com'), findsOneWidget);
    expect(find.text('Casey'), findsOneWidget);

    // Display name field is first, username second.
    await tester.enterText(find.byType(TextFormField).at(1), 'casey_1');
    await tester.pump();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(patchedMeBody, {'display_name': 'Casey', 'username': 'casey_1'});
    // Back on the hub with the refreshed profile summary.
    expect(find.text('Units'), findsOneWidget);
    expect(find.textContaining('Casey'), findsOneWidget);
  });

  testWidgets('focus page enforces the 4-pick limit and saves the order', (
    tester,
  ) async {
    enlargeView(tester);

    Map<String, dynamic>? patchedPrefsBody;

    final prefsDio = _stubDio((options, handler) {
      if (options.method == 'PATCH') {
        patchedPrefsBody = Map<String, dynamic>.from(options.data as Map);
      }
      handler.resolve(
        Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'weight_unit': 'kg',
            'height_unit': 'cm',
            'energy_unit': 'kcal',
            'focus_nutrients': ['protein', 'fat', 'fiber', 'sugars'],
          },
        ),
      );
    });

    UserPreferences? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: AccountPage(
          accessToken: 'token',
          preferencesApi: PreferencesApiService(
            accessToken: 'token',
            dio: prefsDio,
          ),
          authService: AuthService(dio: authStub()),
          onLogout: () async {},
          initialPreferences: const UserPreferences(),
          onSaved: (prefs) => saved = prefs,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The hub row summarizes the default trio.
    expect(find.text('Focus nutrients'), findsOneWidget);
    expect(find.text('Protein · Carbs · Fat'), findsOneWidget);

    await tester.tap(find.text('Focus nutrients'));
    await tester.pumpAndSettle();

    // Defaults are pre-selected: swap carbs out, add fiber and sugars.
    await tester.tap(find.byKey(const Key('focusChoice_carbs')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('focusChoice_fiber')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('focusChoice_sugars')));
    await tester.pump();

    // At the limit of 4, unselected chips are disabled.
    expect(find.text('4 of 4'), findsOneWidget);
    final saltChip = tester.widget<FilterChip>(
      find.byKey(const Key('focusChoice_salt')),
    );
    expect(saltChip.onSelected, isNull);

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    // Tap order becomes display order in the PATCH and the saved snapshot.
    expect(patchedPrefsBody, isNotNull);
    expect(patchedPrefsBody!['focus_nutrients'], [
      'protein',
      'fat',
      'fiber',
      'sugars',
    ]);
    expect(saved?.focusNutrients, ['protein', 'fat', 'fiber', 'sugars']);
    // Back on the hub with the summary refreshed.
    expect(find.text('Protein · Fat · Fiber · Sugars'), findsOneWidget);
  });

  testWidgets('backing out of a dirty goals page asks before discarding', (
    tester,
  ) async {
    enlargeView(tester);

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
          initialPreferences: const UserPreferences(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Daily goals'));
    await tester.pumpAndSettle();

    // Edit the calorie goal, then try to leave without saving.
    await tester.enterText(find.byType(TextFormField).first, '1800');
    await tester.pump(); // let the dirty flag propagate into the PopScope
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('Discard changes?'), findsOneWidget);

    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget); // still on goals page

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    // Back on the hub without saving anything.
    expect(find.text('Units'), findsOneWidget);
    expect(find.text('Save changes'), findsNothing);
  });
}
