from __future__ import annotations

from datetime import datetime

from django.conf import settings
from django.contrib.auth.models import AbstractBaseUser
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

    user: models.OneToOneField[AbstractBaseUser, AbstractBaseUser] = (
        models.OneToOneField(
            settings.AUTH_USER_MODEL,
            on_delete=models.CASCADE,
            related_name="preferences",
        )
    )
    weight_unit: models.CharField[str, str] = models.CharField(
        max_length=8,
        choices=WEIGHT_UNIT_CHOICES,
        default=WEIGHT_UNIT_KG,
    )
    height_unit: models.CharField[str, str] = models.CharField(
        max_length=8,
        choices=HEIGHT_UNIT_CHOICES,
        default=HEIGHT_UNIT_CM,
    )
    energy_unit: models.CharField[str, str] = models.CharField(
        max_length=8,
        choices=ENERGY_UNIT_CHOICES,
        default=ENERGY_UNIT_KCAL,
    )
    daily_calorie_goal: models.PositiveIntegerField[int | None, int | None] = (
        models.PositiveIntegerField(null=True, blank=True)
    )
    weekly_workouts_goal: models.PositiveSmallIntegerField[int | None, int | None] = (
        models.PositiveSmallIntegerField(null=True, blank=True)
    )
    created_at: models.DateTimeField[datetime, datetime] = models.DateTimeField(
        auto_now_add=True
    )
    updated_at: models.DateTimeField[datetime, datetime] = models.DateTimeField(
        auto_now=True
    )

    def __str__(self) -> str:
        return f"Preferences({self.user.pk})"
