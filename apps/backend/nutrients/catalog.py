"""Curated catalog of the nutrients the app surfaces.

This is the server-side twin of the mobile app's `nutrient_catalog.dart`: the same
keys, Open Food Facts field mappings, canonical units and grouping. It drives the
generic per-day `nutrients` map returned by the day endpoint and seeds the
``NutrientDefinition`` rows (see the data migration).

OFF stores a nutrient's per-100g value under ``<off_key>_100g`` and its unit under
``<off_key>_unit``; ``unit`` here is the canonical unit we normalize to.
"""

from dataclasses import dataclass

GROUP_MACROS = "macros"
GROUP_VITAMINS = "vitamins"
GROUP_MINERALS = "minerals"
GROUP_OTHER = "other"


@dataclass(frozen=True)
class NutrientSpec:
    key: str
    off_key: str
    display_name: str
    unit: str
    group: str


NUTRIENT_CATALOG: tuple[NutrientSpec, ...] = (
    # Macros
    NutrientSpec("protein", "proteins", "Protein", "g", GROUP_MACROS),
    NutrientSpec("carbs", "carbohydrates", "Carbs", "g", GROUP_MACROS),
    NutrientSpec("sugars", "sugars", "Sugars", "g", GROUP_MACROS),
    NutrientSpec("fat", "fat", "Fat", "g", GROUP_MACROS),
    NutrientSpec("saturated_fat", "saturated-fat", "Saturated fat", "g", GROUP_MACROS),
    NutrientSpec("fiber", "fiber", "Fiber", "g", GROUP_MACROS),
    # Vitamins
    NutrientSpec("vitamin_a", "vitamin-a", "Vitamin A", "µg", GROUP_VITAMINS),
    NutrientSpec("vitamin_c", "vitamin-c", "Vitamin C", "mg", GROUP_VITAMINS),
    NutrientSpec("vitamin_d", "vitamin-d", "Vitamin D", "µg", GROUP_VITAMINS),
    NutrientSpec("vitamin_e", "vitamin-e", "Vitamin E", "mg", GROUP_VITAMINS),
    NutrientSpec("vitamin_b6", "vitamin-b6", "Vitamin B6", "mg", GROUP_VITAMINS),
    NutrientSpec("folate", "vitamin-b9", "Folate (B9)", "µg", GROUP_VITAMINS),
    NutrientSpec("vitamin_b12", "vitamin-b12", "Vitamin B12", "µg", GROUP_VITAMINS),
    # Minerals
    NutrientSpec("sodium", "sodium", "Sodium", "mg", GROUP_MINERALS),
    NutrientSpec("salt", "salt", "Salt", "g", GROUP_MINERALS),
    NutrientSpec("calcium", "calcium", "Calcium", "mg", GROUP_MINERALS),
    NutrientSpec("iron", "iron", "Iron", "mg", GROUP_MINERALS),
    NutrientSpec("potassium", "potassium", "Potassium", "mg", GROUP_MINERALS),
    NutrientSpec("magnesium", "magnesium", "Magnesium", "mg", GROUP_MINERALS),
    NutrientSpec("zinc", "zinc", "Zinc", "mg", GROUP_MINERALS),
    # Other
    NutrientSpec("cholesterol", "cholesterol", "Cholesterol", "mg", GROUP_OTHER),
)
