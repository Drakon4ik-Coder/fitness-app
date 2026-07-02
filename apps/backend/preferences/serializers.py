from __future__ import annotations

from rest_framework import serializers

from nutrients.catalog import NUTRIENT_CATALOG
from preferences.models import UserPreferences

# The set of nutrient keys a client may personalize. Mirrors the mobile
# ``nutrient_catalog.dart`` keys; anything else is rejected so a typo never
# silently persists an override no page will read.
_CATALOG_KEYS = frozenset(spec.key for spec in NUTRIENT_CATALOG)


class UserPreferencesSerializer(serializers.ModelSerializer):
    class Meta:
        model = UserPreferences
        fields = (
            "weight_unit",
            "height_unit",
            "energy_unit",
            "daily_calorie_goal",
            "weekly_workouts_goal",
            "nutrient_goals",
        )

    def validate_nutrient_goals(self, value: object) -> dict:
        if not isinstance(value, dict):
            raise serializers.ValidationError("Expected an object of nutrient goals.")
        cleaned: dict[str, float] = {}
        for key, raw in value.items():
            if key not in _CATALOG_KEYS:
                raise serializers.ValidationError(f"Unknown nutrient '{key}'.")
            if isinstance(raw, bool) or not isinstance(raw, (int, float)):
                raise serializers.ValidationError(f"Goal for '{key}' must be a number.")
            if raw <= 0:
                raise serializers.ValidationError(
                    f"Goal for '{key}' must be greater than 0."
                )
            cleaned[key] = float(raw)
        return cleaned
