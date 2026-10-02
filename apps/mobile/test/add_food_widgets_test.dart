import 'package:fitness_app/features/nutrition/widgets/add_food_log_bar.dart';
import 'package:fitness_app/features/nutrition/widgets/add_food_search_header.dart';
import 'package:fitness_app/features/nutrition/widgets/food_result_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Direct tests for the widgets extracted from the add-food page (KAN-124).
/// The page-level flows stay covered by add_food_page_test.dart; these pin
/// each widget's own contract.
Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('RateLimitCountdown', () {
    test('ticks each running window down to zero, never below', () {
      const start = RateLimitCountdown(offSeconds: 2, fatsecretSeconds: 1);
      final once = start.tick();
      expect(once, const RateLimitCountdown(offSeconds: 1));
      expect(once.isActive, isTrue);
      final twice = once.tick();
      expect(twice, const RateLimitCountdown());
      expect(twice.isActive, isFalse);
      expect(twice.tick(), twice);
    });

    test('copyWith replaces only the given budget', () {
      const start = RateLimitCountdown(offSeconds: 5, fatsecretSeconds: 9);
      expect(
        start.copyWith(offSeconds: 1),
        const RateLimitCountdown(offSeconds: 1, fatsecretSeconds: 9),
      );
    });
  });

  group('AddFoodSearchHeader', () {
    Future<ValueNotifier<RateLimitCountdown>> pumpHeader(
      WidgetTester tester,
    ) async {
      final countdown = ValueNotifier(const RateLimitCountdown());
      final controller = TextEditingController();
      addTearDown(countdown.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(
          AddFoodSearchHeader(
            controller: controller,
            onScan: null,
            isLoading: false,
            message: null,
            messageTone: null,
            rateLimit: countdown,
          ),
        ),
      );
      return countdown;
    }

    testWidgets('shows no notice while no budget is paused', (tester) async {
      await pumpHeader(tester);
      expect(find.textContaining('paused'), findsNothing);
    });

    testWidgets('an OFF pause mentions scan; a FatSecret-only pause does '
        'not, and the longer window is the countdown', (tester) async {
      final countdown = await pumpHeader(tester);

      countdown.value = const RateLimitCountdown(
        offSeconds: 3,
        fatsecretSeconds: 7,
      );
      await tester.pump();
      expect(
        find.text('Online search and barcode scan paused — resuming in 7s'),
        findsOneWidget,
      );

      countdown.value = const RateLimitCountdown(fatsecretSeconds: 4);
      await tester.pump();
      expect(
        find.text('Restaurant search paused — resuming in 4s'),
        findsOneWidget,
      );

      countdown.value = const RateLimitCountdown();
      await tester.pump();
      expect(find.textContaining('paused'), findsNothing);
    });
  });

  group('AddFoodLogBar', () {
    testWidgets('summarizes the staged items and submits', (tester) async {
      var submitted = 0;
      await tester.pumpWidget(
        _host(
          AddFoodLogBar(
            itemCount: 1,
            totalKcal: 420,
            mealLabel: 'Lunch',
            isSubmitting: false,
            onSubmit: () => submitted++,
          ),
        ),
      );
      expect(find.text('1 item'), findsOneWidget);
      expect(find.text('420 kcal total'), findsOneWidget);
      await tester.tap(find.text('Log to Lunch'));
      expect(submitted, 1);
    });

    testWidgets('disables the button and shows a spinner while submitting', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          AddFoodLogBar(
            itemCount: 3,
            totalKcal: 900,
            mealLabel: 'Dinner',
            isSubmitting: true,
            onSubmit: () {},
          ),
        ),
      );
      expect(find.text('3 items'), findsOneWidget);
      expect(find.text('Log to Dinner'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });
  });

  group('FoodResultsHeader', () {
    testWidgets('hides the filter toggle when no label is given', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          FoodResultsHeader(
            heading: 'Search Results',
            toggleLabel: null,
            onToggleFilter: () {},
          ),
        ),
      );
      expect(find.text('SEARCH RESULTS'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('the toggle fires its callback', (tester) async {
      var toggled = 0;
      await tester.pumpWidget(
        _host(
          FoodResultsHeader(
            heading: 'Recent Foods',
            toggleLabel: 'Favorites',
            onToggleFilter: () => toggled++,
          ),
        ),
      );
      await tester.tap(find.text('Favorites'));
      expect(toggled, 1);
    });
  });
}
