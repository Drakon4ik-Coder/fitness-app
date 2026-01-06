from __future__ import annotations

from datetime import datetime

from django.conf import settings
from django.contrib.auth.models import AbstractBaseUser
from django.db import models


class NutrientDefinition(models.Model):
    key: models.CharField[str, str] = models.CharField(max_length=64, unique=True)
    display_name: models.CharField[str, str] = models.CharField(max_length=128)
    unit: models.CharField[str, str] = models.CharField(max_length=32)
    is_user_defined: models.BooleanField[bool, bool] = models.BooleanField(
        default=False
    )
    owner: models.ForeignKey[AbstractBaseUser | None, AbstractBaseUser | None] = (
        models.ForeignKey(
            settings.AUTH_USER_MODEL,
            on_delete=models.SET_NULL,
            null=True,
            blank=True,
            related_name="nutrient_definitions",
        )
    )
    created_at: models.DateTimeField[datetime, datetime] = models.DateTimeField(
        auto_now_add=True
    )
    updated_at: models.DateTimeField[datetime, datetime] = models.DateTimeField(
        auto_now=True
    )

    def __str__(self) -> str:
        return f"{self.display_name} ({self.key})"
