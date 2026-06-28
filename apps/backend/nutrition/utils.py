from collections.abc import Iterable
from decimal import Decimal, ROUND_HALF_UP

from foods.models import FoodItem


def _decimal_or_zero(value: Decimal | None) -> Decimal:
    return value if value is not None else Decimal("0")


def calculate_macros(item: FoodItem, quantity_g: Decimal | None) -> dict[str, Decimal]:
    factor = _decimal_or_zero(quantity_g) / Decimal("100")
    return {
        "kcal": _decimal_or_zero(item.kcal_100g) * factor,
        "protein_g": _decimal_or_zero(item.protein_g_100g) * factor,
        "carbs_g": _decimal_or_zero(item.carbs_g_100g) * factor,
        "fat_g": _decimal_or_zero(item.fat_g_100g) * factor,
    }


def serialize_decimal(value: Decimal) -> float:
    return float(value.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def _median(values: list[float]) -> float:
    ordered = sorted(values)
    n = len(ordered)
    mid = n // 2
    if n % 2 == 1:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0


# A meal type needs at least this many logged entries before we trust a learned
# typical time over the population default — too few and one odd late dinner
# skews the median.
MIN_MEAL_SAMPLES = 4

# Clamp the learned spread so a user with very consistent (or very erratic)
# timing still gets a sane window, in hours.
_MIN_HALF_WIDTH = 1.0
_MAX_HALF_WIDTH = 3.0


def summarize_meal_time(hours: Iterable[float]) -> dict[str, float | int] | None:
    """Summarize when a meal is typically eaten from a set of hour-of-day values.

    ``hours`` are fractional hours (e.g. 12.5 for 12:30). Returns the median hour
    and a data-derived half-width (half the inter-quartile range, clamped), or
    ``None`` when there aren't enough samples to be meaningful.
    """
    values = [h for h in hours]
    if len(values) < MIN_MEAL_SAMPLES:
        return None
    ordered = sorted(values)
    typical = _median(ordered)
    mid = len(ordered) // 2
    lower = ordered[:mid]
    upper = ordered[mid + 1 :] if len(ordered) % 2 == 1 else ordered[mid:]
    iqr = _median(upper) - _median(lower) if lower and upper else 0.0
    half_width = max(_MIN_HALF_WIDTH, min(_MAX_HALF_WIDTH, iqr / 2.0))
    return {
        "typical_hour": round(typical, 2),
        "half_width": round(half_width, 2),
        "sample_count": len(values),
    }
