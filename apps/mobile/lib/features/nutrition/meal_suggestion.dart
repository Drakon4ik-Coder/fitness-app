import 'data/food_models.dart' show MealType;
import 'data/nutrition_api_service.dart' show MealTimeStat, NutritionEntry;

/// How recently the slot's main meal must have been logged for us to assume the
/// user is now topping up with a snack rather than re-logging that meal.
const Duration _recentMealWindow = Duration(hours: 2);

/// A meal's typical time-of-day, expressed as a centre hour and a half-width
/// (both fractional hours, e.g. 12.5 == 12:30). A given moment belongs to the
/// meal whose centre it is nearest to, provided it falls within that half-width;
/// otherwise it's snack time.
class MealWindow {
  const MealWindow({required this.centerHour, required this.halfWidth});

  final double centerHour;
  final double halfWidth;
}

/// Evidence-based default windows, approximating Western meal-time norms from
/// time-use surveys and chrono-nutrition research: breakfast peaks ~08:00
/// (most 06:00–10:00), lunch ~12:45 (most 11:00–14:30), dinner ~19:00 (most
/// 17:00–21:00). The gaps between them (mid-morning, mid-afternoon, late night)
/// fall through to [MealType.snacks].
const Map<MealType, MealWindow> _defaultWindows = {
  MealType.breakfast: MealWindow(centerHour: 8.0, halfWidth: 2.0),
  MealType.lunch: MealWindow(centerHour: 12.75, halfWidth: 1.75),
  MealType.dinner: MealWindow(centerHour: 19.0, halfWidth: 2.0),
};

/// Builds per-meal windows, preferring the user's learned times from
/// [fetchMealTimes] and falling back to the population defaults for any meal
/// without enough history. Keys are meal-type names ('breakfast'/'lunch'/'dinner').
Map<MealType, MealWindow> buildMealWindows(Map<String, MealTimeStat>? learned) {
  final windows = <MealType, MealWindow>{};
  for (final meal in const [
    MealType.breakfast,
    MealType.lunch,
    MealType.dinner,
  ]) {
    final stat = learned?[meal.wireName];
    windows[meal] = stat != null
        ? MealWindow(centerHour: stat.typicalHour, halfWidth: stat.halfWidth)
        : _defaultWindows[meal]!;
  }
  return windows;
}

/// Picks the meal type the user is most likely adding to, from the current
/// wall-clock time, their typical meal windows, and what they've logged today.
///
/// The base guess is the meal window nearest to [now] (snacks if [now] sits in a
/// between-meals gap). It's then nudged to [MealType.snacks] when that meal was
/// already eaten within [_recentMealWindow] — e.g. lunch logged an hour ago and
/// it's too early for dinner, so the next add is probably a snack.
///
/// [windows] defaults to the population windows; pass [buildMealWindows] output
/// to personalize. [mealsLogged] is the day's entries keyed by meal-type name.
MealType suggestMealType({
  required DateTime now,
  required Map<String, List<NutritionEntry>> mealsLogged,
  Map<MealType, MealWindow>? windows,
}) {
  final slot = _mealForHour(now, windows ?? _defaultWindows);

  if (slot != MealType.snacks &&
      _hasRecentEntry(mealsLogged[slot.wireName], now)) {
    return MealType.snacks;
  }
  return slot;
}

/// The main meal whose window is nearest [now], or [MealType.snacks] if [now] is
/// outside every window (a between-meals gap).
MealType _mealForHour(DateTime now, Map<MealType, MealWindow> windows) {
  final hour = now.hour + now.minute / 60.0;
  MealType best = MealType.snacks;
  double bestDistance = double.infinity;
  for (final entry in windows.entries) {
    final distance = (hour - entry.value.centerHour).abs();
    if (distance <= entry.value.halfWidth && distance < bestDistance) {
      bestDistance = distance;
      best = entry.key;
    }
  }
  return best;
}

bool _hasRecentEntry(List<NutritionEntry>? entries, DateTime now) {
  if (entries == null || entries.isEmpty) return false;
  for (final entry in entries) {
    // difference() is instant-based, so a UTC consumed_at compares correctly
    // against local now without manual timezone conversion.
    if (now.difference(entry.consumedAt).abs() <= _recentMealWindow) {
      return true;
    }
  }
  return false;
}
