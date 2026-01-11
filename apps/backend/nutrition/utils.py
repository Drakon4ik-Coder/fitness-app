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
