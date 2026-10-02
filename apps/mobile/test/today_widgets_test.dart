import 'package:fitness_app/features/nutrition/data/nutrient_catalog.dart';
import 'package:fitness_app/features/nutrition/widgets/focus_nutrients_card.dart';
import 'package:fitness_app/features/nutrition/widgets/today_date_bar.dart';
import 'package:fitness_app/features/nutrition/widgets/today_meal_cards.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Direct tests for the widgets extracted from the today page (KAN-124). The
/// page-level flows stay covered by nutrition_today_test.dart; these pin each
/// widget's own contract.
Widget _host(Widget child) => MaterialApp(
  theme: LuminaHealthTheme.dark(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

const _protein = NutrientSpec(
  key: 'protein',
  offKey: 'proteins',
  label: 'Protein',
  unit: 'g',
  group: NutrientGroup.macros,
  dailyTarget: 100,
);

void main() {
  testWidgets('PendingSyncChip pluralizes its count', (tester) async {
    await tester.pumpWidget(_host(const PendingSyncChip(count: 1)));
    expect(find.text('1 change waiting to sync'), findsOneWidget);

    await tester.pumpWidget(_host(const PendingSyncChip(count: 3)));
    expect(find.text('3 changes waiting to sync'), findsOneWidget);
  });

  testWidgets('DailyLogsHeader shows the day entry count', (tester) async {
    await tester.pumpWidget(_host(const DailyLogsHeader(totalEntries: 4)));
    expect(find.text('4 entries'), findsOneWidget);
  });

  group('FocusNutrientsCard status line', () {
    Future<void> pumpTile(WidgetTester tester, FocusSummary summary) {
      return tester.pumpWidget(
        _host(FocusNutrientsCard(summaries: [summary], warnNutrients: {})),
      );
    }

    testWidgets('under goal reads as amount left', (tester) async {
      await pumpTile(tester, const FocusSummary(spec: _protein, amount: 60));
      expect(find.text('40g left'), findsOneWidget);
    });

    testWidgets('over goal shows the overshoot', (tester) async {
      await pumpTile(tester, const FocusSummary(spec: _protein, amount: 120));
      expect(find.textContaining('+20g'), findsOneWidget);
      expect(find.textContaining('left'), findsNothing);
    });

    testWidgets('an incomplete total is marked as an estimate, never over', (
      tester,
    ) async {
      await pumpTile(
        tester,
        const FocusSummary(spec: _protein, amount: 120, incomplete: true),
      );
      expect(find.text('incomplete'), findsOneWidget);
      expect(find.text('~120g'), findsOneWidget);
      expect(find.textContaining('+20g'), findsNothing);
    });

    testWidgets('no reported amount reads as no data', (tester) async {
      await pumpTile(tester, const FocusSummary(spec: _protein, amount: null));
      expect(find.text('no data'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
    });
  });
}
