import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/features/main_shell.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/data/preferences_api_service.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'in_memory_nutrition_store.dart';

Dio _stub(Map<String, dynamic> data) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response(requestOptions: options, statusCode: 200, data: data),
      ),
    ),
  );
  return dio;
}

MainShell _shell() {
  final nutritionApi = NutritionApiService(
    accessToken: 'token',
    dio: _stub({
      'date': '2024-01-01',
      'totals': {'kcal': 0, 'protein_g': 0, 'carbs_g': 0, 'fat_g': 0},
      'meals': {'breakfast': [], 'lunch': [], 'dinner': [], 'snacks': []},
    }),
  );
  final preferencesApi = PreferencesApiService(
    accessToken: 'token',
    dio: _stub({
      'weight_unit': 'kg',
      'height_unit': 'cm',
      'energy_unit': 'kcal',
      'daily_calorie_goal': null,
      'nutrient_goals': <String, dynamic>{},
    }),
  );
  final authService = AuthService(
    dio: _stub({'email': 'me@example.com', 'display_name': 'Casey'}),
  );
  return MainShell(
    accessToken: 'token',
    onLogout: () async {},
    nutritionApi: nutritionApi,
    localStore: InMemoryNutritionStore(),
    preferencesApi: preferencesApi,
    authService: authService,
  );
}

/// The nav item's semantics node. The settings tab's app bar is also titled
/// "Settings", so a bare label match is ambiguous once that tab is on stage;
/// filtering to buttons isolates the bar item.
FinderBase<SemanticsNode> _navItem(String label) => find.semantics.byPredicate(
  (node) => node.label == label && node.flagsCollection.isButton,
  describeMatch: (plurality) => 'nav item "$label"',
);

/// The nav item's visible label, scoped to its Semantics wrapper so an
/// identically-worded page title elsewhere can't match.
Finder _navLabelText(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        w.properties.label == label &&
        (w.properties.button ?? false),
  ),
  matching: find.text(label),
);

void main() {
  testWidgets('renders both nav tabs and defaults to Nutrition selected', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(theme: LuminaHealthTheme.dark(), home: _shell()),
    );
    await tester.pumpAndSettle();

    expect(_navItem('Nutrition'), findsOne);
    expect(_navItem('Settings'), findsOne);

    expect(
      _navItem('Nutrition').evaluate().single,
      containsSemantics(isSelected: true),
    );
    expect(
      _navItem('Settings').evaluate().single,
      containsSemantics(isSelected: false),
    );
    handle.dispose();
  });

  testWidgets('tapping Settings selects the settings tab', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(theme: LuminaHealthTheme.dark(), home: _shell()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Settings'));
    await tester.pumpAndSettle();

    expect(
      _navItem('Settings').evaluate().single,
      containsSemantics(isSelected: true),
    );
    expect(
      _navItem('Nutrition').evaluate().single,
      containsSemantics(isSelected: false),
    );
    handle.dispose();
  });

  // KAN-62: the labels are real Text widgets (scalable, localizable), not
  // glyphs baked into the SVG assets.
  testWidgets('nav labels render as Text widgets', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: LuminaHealthTheme.dark(), home: _shell()),
    );
    await tester.pumpAndSettle();

    expect(_navLabelText('Nutrition'), findsOneWidget);
    expect(_navLabelText('Settings'), findsOneWidget);
  });

  testWidgets('nav bar grows past its 64px floor at max text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    await tester.pumpWidget(
      MaterialApp(theme: LuminaHealthTheme.dark(), home: _shell()),
    );
    // Any RenderFlex overflow anywhere in the shell fails this pump.
    await tester.pumpAndSettle();

    final item = find
        .ancestor(
          of: _navLabelText('Nutrition'),
          matching: find.byType(InkWell),
        )
        .first;
    expect(tester.getSize(item).height, greaterThan(64));
  });
}
