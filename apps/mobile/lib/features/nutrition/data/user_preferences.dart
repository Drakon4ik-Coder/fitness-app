import 'food_models.dart' show parseNullableDouble;

/// The signed-in user's preferences: unit choices and daily goals. Mirrors the
/// backend `UserPreferences` (`/api/v1/preferences/`). Goals the user hasn't
/// personalized are absent — callers fall back to the catalog defaults
/// (`resolveCatalog`) and [kDefaultCalorieGoal].
class UserPreferences {
  const UserPreferences({
    this.weightUnit = 'kg',
    this.heightUnit = 'cm',
    this.energyUnit = 'kcal',
    this.calorieGoal,
    this.nutrientGoals = const {},
  });

  final String weightUnit;
  final String heightUnit;
  final String energyUnit;

  /// Daily energy budget in kcal, or null when the user hasn't set one.
  final int? calorieGoal;

  /// Per-nutrient daily target overrides, keyed by catalog key, in each
  /// nutrient's canonical unit. Empty when the user hasn't personalized any.
  final Map<String, double> nutrientGoals;

  factory UserPreferences.fromJson(Map<String, dynamic> json) {
    final rawGoals = json['nutrient_goals'];
    final goals = <String, double>{};
    if (rawGoals is Map) {
      for (final entry in rawGoals.entries) {
        final value = parseNullableDouble(entry.value);
        if (value != null) goals[entry.key.toString()] = value;
      }
    }
    return UserPreferences(
      weightUnit: (json['weight_unit'] as String?) ?? 'kg',
      heightUnit: (json['height_unit'] as String?) ?? 'cm',
      energyUnit: (json['energy_unit'] as String?) ?? 'kcal',
      calorieGoal: (json['daily_calorie_goal'] as num?)?.toInt(),
      nutrientGoals: goals,
    );
  }

  UserPreferences copyWith({
    String? weightUnit,
    String? heightUnit,
    String? energyUnit,
    int? calorieGoal,
    bool clearCalorieGoal = false,
    Map<String, double>? nutrientGoals,
  }) {
    return UserPreferences(
      weightUnit: weightUnit ?? this.weightUnit,
      heightUnit: heightUnit ?? this.heightUnit,
      energyUnit: energyUnit ?? this.energyUnit,
      calorieGoal: clearCalorieGoal ? null : (calorieGoal ?? this.calorieGoal),
      nutrientGoals: nutrientGoals ?? this.nutrientGoals,
    );
  }
}
