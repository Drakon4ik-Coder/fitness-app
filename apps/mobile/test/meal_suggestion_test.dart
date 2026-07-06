import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart'
    show MealTimeStat, NutritionEntry;
import 'package:fitness_app/features/nutrition/meal_suggestion.dart';

NutritionEntry _entry(String mealType, DateTime consumedAt) {
  return NutritionEntry(
    id: 1,
    mealType: mealType,
    consumedAt: consumedAt,
    quantityG: 100,
    kcal: 200,
    foodItem: FoodItem(
      source: offSource,
      externalId: 'x',
      name: 'Test',
      brands: '',
      rawSourceJson: '{}',
    ),
  );
}

void main() {
  group('suggestMealType time slots', () {
    test('morning suggests breakfast', () {
      final meal = suggestMealType(
        now: DateTime(2026, 6, 28, 8),
        mealsLogged: const {},
      );
      expect(meal, MealType.breakfast);
    });

    test('midday suggests lunch', () {
      final meal = suggestMealType(
        now: DateTime(2026, 6, 28, 12, 30),
        mealsLogged: const {},
      );
      expect(meal, MealType.lunch);
    });

    test('evening suggests dinner', () {
      final meal = suggestMealType(
        now: DateTime(2026, 6, 28, 19),
        mealsLogged: const {},
      );
      expect(meal, MealType.dinner);
    });

    test('mid-afternoon gap suggests snacks', () {
      final meal = suggestMealType(
        now: DateTime(2026, 6, 28, 16),
        mealsLogged: const {},
      );
      expect(meal, MealType.snacks);
    });

    test('late night suggests snacks', () {
      final meal = suggestMealType(
        now: DateTime(2026, 6, 28, 23, 30),
        mealsLogged: const {},
      );
      expect(meal, MealType.snacks);
    });
  });

  group('suggestMealType recency nudge', () {
    test('lunch eaten an hour ago, too early for dinner -> snacks', () {
      final now = DateTime(2026, 6, 28, 14);
      final meal = suggestMealType(
        now: now,
        mealsLogged: {
          'lunch': [_entry('lunch', now.subtract(const Duration(hours: 1)))],
        },
      );
      expect(meal, MealType.snacks);
    });

    test('lunch window but lunch not yet eaten -> lunch', () {
      final now = DateTime(2026, 6, 28, 14);
      final meal = suggestMealType(
        now: now,
        mealsLogged: {
          'breakfast': [
            _entry('breakfast', now.subtract(const Duration(hours: 6))),
          ],
        },
      );
      expect(meal, MealType.lunch);
    });

    test('old lunch entry (3h ago) still suggests lunch', () {
      final now = DateTime(2026, 6, 28, 14);
      final meal = suggestMealType(
        now: now,
        mealsLogged: {
          'lunch': [_entry('lunch', now.subtract(const Duration(hours: 3)))],
        },
      );
      expect(meal, MealType.lunch);
    });

    test('recency uses true instant across UTC consumed_at', () {
      // consumed_at returned in UTC; now is local. 1h earlier instant.
      final now = DateTime(2026, 6, 28, 12, 30);
      final meal = suggestMealType(
        now: now,
        mealsLogged: {
          'lunch': [
            _entry('lunch', now.toUtc().subtract(const Duration(hours: 1))),
          ],
        },
      );
      expect(meal, MealType.snacks);
    });
  });

  group('personalized windows', () {
    test('learned late dinner shifts the dinner window', () {
      final windows = buildMealWindows({
        'dinner': const MealTimeStat(
          typicalHour: 21.0,
          halfWidth: 1.5,
          sampleCount: 20,
        ),
      });
      // 21:00 is snacks under the default window but dinner for this late eater.
      final atNine = suggestMealType(
        now: DateTime(2026, 6, 28, 21),
        mealsLogged: const {},
        windows: windows,
      );
      expect(atNine, MealType.dinner);
    });

    test('learned early lunch leaves default 13:00 as a gap', () {
      final windows = buildMealWindows({
        'lunch': const MealTimeStat(
          typicalHour: 11.0,
          halfWidth: 1.0,
          sampleCount: 12,
        ),
      });
      // This user lunches ~11:00; by 13:00 it's snack territory for them.
      final atOne = suggestMealType(
        now: DateTime(2026, 6, 28, 13),
        mealsLogged: const {},
        windows: windows,
      );
      expect(atOne, MealType.snacks);
    });

    test('meals without learned data keep population defaults', () {
      final windows = buildMealWindows({
        'dinner': const MealTimeStat(
          typicalHour: 21.0,
          halfWidth: 1.5,
          sampleCount: 20,
        ),
      });
      final atEight = suggestMealType(
        now: DateTime(2026, 6, 28, 8),
        mealsLogged: const {},
        windows: windows,
      );
      expect(atEight, MealType.breakfast);
    });
  });
}
