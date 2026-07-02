from django.conf import settings
from django.db import models


class UserPreferences(models.Model):
    WEIGHT_UNIT_KG = "kg"
    WEIGHT_UNIT_LB = "lb"
    WEIGHT_UNIT_CHOICES = [
        (WEIGHT_UNIT_KG, "kg"),
        (WEIGHT_UNIT_LB, "lb"),
    ]

    HEIGHT_UNIT_CM = "cm"
    HEIGHT_UNIT_IN = "in"
    HEIGHT_UNIT_CHOICES = [
        (HEIGHT_UNIT_CM, "cm"),
        (HEIGHT_UNIT_IN, "in"),
    ]

    ENERGY_UNIT_KCAL = "kcal"
    ENERGY_UNIT_KJ = "kj"
    ENERGY_UNIT_CHOICES = [
        (ENERGY_UNIT_KCAL, "kcal"),
        (ENERGY_UNIT_KJ, "kj"),
    ]

    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="preferences",
    )
    weight_unit = models.CharField(
        max_length=8,
        choices=WEIGHT_UNIT_CHOICES,
        default=WEIGHT_UNIT_KG,
    )
    height_unit = models.CharField(
        max_length=8,
        choices=HEIGHT_UNIT_CHOICES,
        default=HEIGHT_UNIT_CM,
    )
    energy_unit = models.CharField(
        max_length=8,
        choices=ENERGY_UNIT_CHOICES,
        default=ENERGY_UNIT_KCAL,
    )
    daily_calorie_goal = models.PositiveIntegerField(null=True, blank=True)
    weekly_workouts_goal = models.PositiveSmallIntegerField(null=True, blank=True)
    # Per-nutrient daily target overrides, keyed by nutrient catalog key
    # (see ``nutrients.catalog``). Only keys the user has personalized are stored;
    # anything absent falls back to the client's catalog default. Values are in the
    # catalog's canonical unit for that nutrient.
    nutrient_goals = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"Preferences({self.user_id})"
