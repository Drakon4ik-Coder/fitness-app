from collections.abc import Iterable
from decimal import Decimal, ROUND_HALF_UP

from foods.models import FoodItem
from nutrients.catalog import NUTRIENT_CATALOG, NutrientSpec


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


# Grams that one of the given unit represents, for converting between OFF's raw
# unit and a nutrient's canonical unit. Non-mass units (e.g. IU) return None and
# are treated as missing rather than converted into a wrong number.
_GRAMS_PER_UNIT: dict[str, Decimal] = {
    "g": Decimal("1"),
    "mg": Decimal("0.001"),
    "µg": Decimal("0.000001"),  # micro sign U+00B5
    "μg": Decimal("0.000001"),  # greek small mu U+03BC
    "ug": Decimal("0.000001"),
    "mcg": Decimal("0.000001"),
    "kg": Decimal("1000"),
}


def _grams_per_unit(unit: str | None) -> Decimal | None:
    return _GRAMS_PER_UNIT.get((unit or "").lower())


def nutrient_per_100g(spec: NutrientSpec, nutriments: dict | None) -> Decimal | None:
    """One nutrient's per-100g value from an OFF nutriments blob, converted into
    the catalog's canonical unit. None when the nutrient is absent or carries a
    unit we can't convert. OFF stores ``<off_key>_100g`` in the unit given by
    ``<off_key>_unit``; a missing unit defaults to grams (OFF's default)."""
    if not nutriments:
        return None
    raw = nutriments.get(f"{spec.off_key}_100g")
    if raw is None:
        return None
    try:
        value = Decimal(str(raw))
    except (ArithmeticError, ValueError, TypeError):
        return None
    source_unit = nutriments.get(f"{spec.off_key}_unit")
    from_grams = _grams_per_unit(source_unit if isinstance(source_unit, str) else "g")
    to_grams = _grams_per_unit(spec.unit)
    if from_grams is None or to_grams is None:
        return None
    return value * from_grams / to_grams


def calculate_nutrients(
    item: FoodItem, quantity_g: Decimal | None
) -> dict[str, Decimal]:
    """Every catalog nutrient present in the food's stored nutriments blob,
    scaled to the logged quantity and keyed by catalog key (in canonical units).
    Nutrients absent from the blob are simply omitted."""
    factor = _decimal_or_zero(quantity_g) / Decimal("100")
    result: dict[str, Decimal] = {}
    nutriments = item.nutriments_json
    for spec in NUTRIENT_CATALOG:
        per_100 = nutrient_per_100g(spec, nutriments)
        if per_100 is None:
            continue
        result[spec.key] = per_100 * factor
    return result


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
