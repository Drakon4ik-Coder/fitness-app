import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/nutrition_today_page.dart';
import 'package:fitness_app/ui_system/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Nutrition Today page shows key sections',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const NutritionTodayPage(),
      ),
    );

    expect(find.text('Today'), findsOneWidget);
    expect(find.textContaining('Add food'), findsOneWidget);
    expect(find.text('Breakfast'), findsOneWidget);
  });
}
