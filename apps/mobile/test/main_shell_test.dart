import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/features/main_shell.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_day_cache.dart';
import 'package:fitness_app/features/nutrition/data/preferences_api_service.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';

/// In-memory [NutritionDayCache] so the shell's today tab doesn't touch sqflite.
class _InMemoryDayCache implements NutritionDayCache {
  final Map<String, Map<String, dynamic>> _store = {};

  @override
  Future<Map<String, dynamic>?> read(String dateKey) async => _store[dateKey];

  @override
  Future<void> write(String dateKey, Map<String, dynamic> payload) async =>
      _store[dateKey] = payload;

  @override
  Future<void> clear() async => _store.clear();

  @override
  Future<void> close() async {}
}

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
    dayCache: _InMemoryDayCache(),
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
}
