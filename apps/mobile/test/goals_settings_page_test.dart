import 'package:dio/dio.dart';
import 'package:fitness_app/features/nutrition/data/preferences_api_service.dart';
import 'package:fitness_app/features/nutrition/data/user_preferences.dart';
import 'package:fitness_app/features/nutrition/settings/goals_settings_page.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void enlargeView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Stubs every PATCH with a defaults snapshot and records the request bodies.
  PreferencesApiService stubApi(List<Map<String, dynamic>> bodies) {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          bodies.add(options.data as Map<String, dynamic>);
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'weight_unit': 'kg',
                'height_unit': 'cm',
                'energy_unit': 'kcal',
                'daily_calorie_goal': null,
                'nutrient_goals': <String, double>{},
              },
            ),
          );
        },
      ),
    );
    return PreferencesApiService(accessToken: 'token', dio: dio);
  }

  // Pushes the page as a route so its pop-on-save has somewhere to go.
  Future<void> pumpGoalsPage(
    WidgetTester tester, {
    required PreferencesApiService api,
    required UserPreferences initial,
  }) async {
    enlargeView(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => GoalsSettingsPage(
                      preferencesApi: api,
                      initialPreferences: initial,
                    ),
                  ),
                ),
                child: const Text('open goals'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open goals'));
    await tester.pumpAndSettle();
  }

  Finder calorieField() => find.ancestor(
    of: find.text('Calories'),
    matching: find.byType(TextFormField),
  );

  // The save button is pinned outside the list (KAN-94), so no scrolling into
  // view is needed regardless of how long the goals form is.
  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
  }

  testWidgets('no calorie override leaves the field blank, and saving the '
      'untouched page does not persist the recommended default', (
    tester,
  ) async {
    final bodies = <Map<String, dynamic>>[];
    await pumpGoalsPage(
      tester,
      api: stubApi(bodies),
      initial: const UserPreferences(),
    );

    final field = tester.widget<TextFormField>(calorieField());
    expect(field.controller!.text, isEmpty);

    await save(tester);

    expect(bodies, hasLength(1));
    expect(bodies.single['daily_calorie_goal'], isNull);
  });

  testWidgets('reset + save clears an existing calorie override with an '
      'explicit null', (tester) async {
    final bodies = <Map<String, dynamic>>[];
    await pumpGoalsPage(
      tester,
      api: stubApi(bodies),
      initial: const UserPreferences(calorieGoal: 2500),
    );

    expect(
      tester.widget<TextFormField>(calorieField()).controller!.text,
      '2500',
    );

    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(
      tester.widget<TextFormField>(calorieField()).controller!.text,
      isEmpty,
    );

    await save(tester);

    expect(bodies, hasLength(1));
    expect(bodies.single.containsKey('daily_calorie_goal'), isTrue);
    expect(bodies.single['daily_calorie_goal'], isNull);
  });

  testWidgets('a typed calorie value is saved as an override', (tester) async {
    final bodies = <Map<String, dynamic>>[];
    await pumpGoalsPage(
      tester,
      api: stubApi(bodies),
      initial: const UserPreferences(),
    );

    await tester.enterText(calorieField(), '1800');
    await save(tester);

    expect(bodies, hasLength(1));
    expect(bodies.single['daily_calorie_goal'], 1800);
  });
}
