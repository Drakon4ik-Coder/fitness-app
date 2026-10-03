import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fitness_app/features/nutrition/add_food_page.dart';
import 'package:fitness_app/features/nutrition/data/food_local_db.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/foods_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/data/off_client.dart';
import 'package:fitness_app/features/nutrition/data/off_rate_limiter.dart';
import 'package:fitness_app/features/nutrition/data/user_preferences.dart';
import 'package:fitness_app/features/nutrition/nutrition_detail_page.dart';
import 'package:fitness_app/features/nutrition/nutrition_today_page.dart';
import 'package:fitness_app/features/nutrition/widgets/meal_detail_sheet.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_dio.dart';
import 'in_memory_nutrition_store.dart';

// Page flows the older today tests don't reach (KAN-131): date navigation,
// load failures, token rotation, the nutrient detail link and the meal sheet's
// error handling.

class _FakeLocalDb extends FoodLocalDb {
  @override
  Future<List<FoodItem>> fetchRecentFoods({int limit = 20}) async => const [];

  @override
  Future<List<FoodItem>> fetchFavorites({int limit = 20}) async => const [];
}

class _FakeFoodsApi extends FoodsApiService {
  _FakeFoodsApi() : super(accessToken: 'test-token');

  @override
  Future<List<FoodItem>> typeahead(String query, {int limit = 10}) async =>
      const [];
}

class _FakeOffClient extends OffClient {
  _FakeOffClient() : super(dio: Dio(), rateLimiter: OffRateLimiter());

  @override
  Future<List<OffProductResponse>> searchProducts(
    String query, {
    int pageSize = 10,
    String? categoryTag,
    CancelToken? cancelToken,
  }) async => const [];
}

String _key(DateTime date) => NutritionApiService.formatDate(date);

DateTime _today() => DateUtils.dateOnly(DateTime.now());

Map<String, dynamic> _day(
  String date, {
  List<Map<String, dynamic>> lunch = const [],
  Map<String, dynamic>? nutrients,
}) => {
  'date': date,
  'totals': {'kcal': 0, 'protein_g': 0, 'carbs_g': 0, 'fat_g': 0},
  'nutrients': ?nutrients,
  'meals': {'breakfast': [], 'lunch': lunch, 'dinner': [], 'snacks': []},
};

/// A server-sent entry. Without [uuid] it is a pre-sync payload entry, whose
/// edits and deletes go straight to the server (no outbox), so server errors
/// reach the page.
Map<String, dynamic> _entry(String date, {String? uuid, int id = 1}) => {
  'id': id,
  'client_uuid': ?uuid,
  'meal_type': 'lunch',
  'consumed_at': '${date}T12:00:00Z',
  'quantity_g': 100,
  'kcal': 150,
  'food_item': {'id': 7, 'name': 'Oatmeal', 'kcal_100g': 150},
};

/// Answers sync and meal-times with empty pages and `/day` from [day].
FutureOr<FakeReply> Function(RequestOptions) _server({
  Map<String, dynamic> Function(String date)? day,
  FutureOr<FakeReply?> Function(RequestOptions request)? override,
}) {
  return (request) async {
    final custom = await override?.call(request);
    if (custom != null) return custom;
    final path = request.path;
    if (path.endsWith('/entries/sync')) {
      return ok({'entries': [], 'next_cursor': 'c1', 'has_more': false});
    }
    if (path.endsWith('/meal-times')) return ok(<String, dynamic>{});
    if (path.endsWith('/day')) {
      final date = request.queryParameters['date'] as String;
      return ok((day ?? _day)(date));
    }
    return ok(<String, dynamic>{});
  };
}

Future<void> _pumpPage(
  WidgetTester tester,
  Dio dio, {
  String token = 'token',
  Future<void> Function()? onLogout,
  UserPreferences? preferences,
  InMemoryNutritionStore? store,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: LuminaHealthTheme.dark(),
      home: NutritionTodayPage(
        accessToken: token,
        onLogout: onLogout ?? () async {},
        nutritionApi: NutritionApiService(accessToken: token, dio: dio),
        localStore: store ?? InMemoryNutritionStore(),
        localDb: _FakeLocalDb(),
        foodsApi: _FakeFoodsApi(),
        offClient: _FakeOffClient(),
        preferences: preferences,
      ),
    ),
  );
}

/// Awaits [future] by pumping frames: Dio completes through timers, which
/// never fire inside the widget test's fake-async zone unless pumped.
Future<T> _settle<T>(WidgetTester tester, Future<T> future) async {
  late T result;
  var done = false;
  unawaited(
    future.then((value) {
      result = value;
      done = true;
    }),
  );
  for (var i = 0; i < 100 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done, isTrue, reason: 'future never completed');
  return result;
}

void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('a 401 while loading logs out', (tester) async {
    var logouts = 0;
    final dio = scriptedDio(
      _server(
        override: (request) =>
            request.path.endsWith('/entries/sync') ? status(401) : null,
      ),
    );
    await _pumpPage(tester, dio, onLogout: () async => logouts++);
    await tester.pumpAndSettle();

    expect(logouts, 1);
    expect(find.byKey(const Key('nutritionLoadingSpinner')), findsNothing);
  });

  testWidgets('a failed first load shows a banner whose Retry recovers', (
    tester,
  ) async {
    var failing = true;
    final dio = scriptedDio(
      _server(
        override: (request) => failing && request.path.endsWith('/entries/sync')
            ? status(500)
            : null,
      ),
    );
    await _pumpPage(tester, dio);
    await tester.pumpAndSettle();
    expect(find.text('Unable to sync nutrition log.'), findsOneWidget);

    failing = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Unable to sync nutrition log.'), findsNothing);
  });

  testWidgets('a slow first load shows the spinner after a second', (
    tester,
  ) async {
    final gate = Completer<void>();
    final dio = scriptedDio(
      _server(
        override: (request) async {
          if (request.path.endsWith('/entries/sync')) await gate.future;
          return null;
        },
      ),
    );
    await _pumpPage(tester, dio);
    await tester.pump();
    expect(find.byKey(const Key('nutritionLoadingSpinner')), findsNothing);

    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.byKey(const Key('nutritionLoadingSpinner')), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nutritionLoadingSpinner')), findsNothing);
  });

  testWidgets('a rotated access token reaches the API clients', (tester) async {
    final log = <RequestOptions>[];
    final dio = scriptedDio(_server(), log: log);
    await _pumpPage(tester, dio, token: 'old');
    await tester.pumpAndSettle();

    await _pumpPage(tester, dio, token: 'new');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Previous day'));
    await tester.pumpAndSettle();

    expect(log.last.headers['Authorization'], 'Bearer new');
  });

  testWidgets('date bar steps back and forward and jumps to today', (
    tester,
  ) async {
    final requested = <String>[];
    final dio = scriptedDio(
      _server(
        day: (date) {
          requested.add(date);
          return _day(date);
        },
      ),
    );
    await _pumpPage(tester, dio);
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.byKey(const Key('todayChip')), findsNothing);

    await tester.tap(find.byTooltip('Previous day'));
    await tester.pumpAndSettle();
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.byKey(const Key('todayChip')), findsOneWidget);

    await tester.tap(find.byTooltip('Previous day'));
    await tester.pumpAndSettle();
    final twoAgo = DateTime(_today().year, _today().month, _today().day - 2);
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    expect(
      find.text('${months[twoAgo.month - 1]} ${twoAgo.day}'),
      findsOneWidget,
    );
    expect(requested, contains(_key(twoAgo)));

    await tester.tap(find.byTooltip('Next day'));
    await tester.pumpAndSettle();
    expect(find.text('Yesterday'), findsOneWidget);

    await tester.tap(find.byKey(const Key('todayChip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('todayChip')), findsNothing);

    // Today's "Next day" is disabled: the future can't be browsed.
    final next = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.chevron_right).first,
    );
    expect(next.onPressed, isNull);
  });

  testWidgets('the date picker jumps to a picked day and ignores no-ops', (
    tester,
  ) async {
    final requested = <String>[];
    final dio = scriptedDio(
      _server(
        day: (date) {
          requested.add(date);
          return _day(date);
        },
      ),
    );
    await _pumpPage(tester, dio);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Previous day'));
    await tester.pumpAndSettle();

    // Cancel and re-confirming the current day both leave the page as is.
    await tester.tap(find.text('Yesterday'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yesterday'));
    await tester.pumpAndSettle();
    final loadsBefore = requested.length;
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(requested.length, loadsBefore);
    expect(find.text('Yesterday'), findsOneWidget);

    // Typing today's date in the picker's input mode moves the page there.
    await tester.tap(find.text('Yesterday'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    final today = _today();
    String two(int n) => n.toString().padLeft(2, '0');
    await tester.enterText(
      find.byType(TextField).last,
      '${two(today.month)}/${two(today.day)}/${today.year}',
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.byKey(const Key('todayChip')), findsNothing);
  });

  testWidgets('View full nutrients opens the detail page and reloads on pop', (
    tester,
  ) async {
    _tallView(tester);
    final log = <RequestOptions>[];
    final dio = scriptedDio(_server(), log: log);
    await _pumpPage(tester, dio);
    await tester.pumpAndSettle();

    await tester.tap(find.text('View full nutrients'));
    await tester.pumpAndSettle();
    expect(find.byType(NutritionDetailPage), findsOneWidget);

    final requestsBefore = log.length;
    Navigator.of(tester.element(find.byType(NutritionDetailPage))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(NutritionDetailPage), findsNothing);
    expect(log.length, greaterThan(requestsBefore));
  });

  testWidgets('focus nutrients mark partial and missing data', (tester) async {
    _tallView(tester);
    // Server map says only 1 of 3 foods reported fiber: a floor, not a total.
    final dio = scriptedDio(
      _server(
        day: (date) => _day(
          date,
          lunch: [_entry(date, uuid: 'u1')],
          nutrients: {
            'fiber': {'amount': 5, 'unit': 'g', 'total': 3, 'reported': 1},
          },
        ),
      ),
    );
    await _pumpPage(
      tester,
      dio,
      preferences: const UserPreferences(focusNutrients: ['fiber']),
    );
    await tester.pumpAndSettle();
    expect(find.text('~5g'), findsOneWidget);
    expect(find.text('incomplete'), findsOneWidget);

    // Without the server map the page aggregates entries itself; the logged
    // food reports no fiber, so the tile reads "no data".
    final aggregated = scriptedDio(
      _server(
        day: (date) => _day(date, lunch: [_entry(date, uuid: 'u1')]),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    await _pumpPage(
      tester,
      aggregated,
      preferences: const UserPreferences(focusNutrients: ['fiber']),
    );
    await tester.pumpAndSettle();
    expect(find.text('no data'), findsOneWidget);
  });

  group('meal sheet callbacks', () {
    Future<MealDetailSheet> openSheet(
      WidgetTester tester,
      FutureOr<FakeReply?> Function(RequestOptions request) override, {
      Future<void> Function()? onLogout,
    }) async {
      _tallView(tester);
      final dio = scriptedDio(
        _server(
          day: (date) => _day(date, lunch: [_entry(date)]),
          override: override,
        ),
      );
      await _pumpPage(tester, dio, onLogout: onLogout);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lunch'));
      await tester.pumpAndSettle();
      return tester.widget<MealDetailSheet>(find.byType(MealDetailSheet));
    }

    bool isWrite(RequestOptions request) =>
        request.method != 'GET' && request.path.contains('/entries');

    testWidgets('a rejected edit or delete shows the server message', (
      tester,
    ) async {
      final sheet = await openSheet(
        tester,
        (request) => isWrite(request) ? status(400) : null,
      );
      final entry = sheet.entries.single;

      expect(
        await _settle(tester, sheet.onUpdateEntry(entry, quantityG: 50)),
        isNull,
      );
      await tester.pump();
      expect(find.text('Unable to update entry.'), findsOneWidget);
      // Clear the first snackbar so the next one isn't queued behind it.
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
          .removeCurrentSnackBar();
      await tester.pumpAndSettle();

      expect(await _settle(tester, sheet.onDeleteEntry(entry)), isFalse);
      await tester.pump();
      expect(find.text('Unable to delete entry.'), findsOneWidget);

      expect(await _settle(tester, sheet.onRestoreEntry(entry)), isNull);
    });

    testWidgets('a 401 on any sheet write logs out', (tester) async {
      var logouts = 0;
      final sheet = await openSheet(
        tester,
        (request) => isWrite(request) ? status(401) : null,
        onLogout: () async => logouts++,
      );
      final entry = sheet.entries.single;

      expect(
        await _settle(tester, sheet.onUpdateEntry(entry, mealType: 'dinner')),
        isNull,
      );
      expect(await _settle(tester, sheet.onDeleteEntry(entry)), isFalse);
      expect(await _settle(tester, sheet.onRestoreEntry(entry)), isNull);
      expect(logouts, 3);
    });

    testWidgets('Add more closes the sheet into add-food for that meal', (
      tester,
    ) async {
      final sheet = await openSheet(tester, (_) => null);
      sheet.onAddMore();
      await tester.pumpAndSettle();
      expect(find.byType(MealDetailSheet), findsNothing);
      final page = tester.widget<AddFoodPage>(find.byType(AddFoodPage));
      expect(page.initialMeal, MealType.lunch);
    });
  });
}
