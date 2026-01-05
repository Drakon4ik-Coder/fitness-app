from __future__ import annotations

from datetime import datetime
from typing import Any

from django.db import models
from django.utils import timezone


class ExternalFoodItemCache(models.Model):
    SOURCE_OPEN_FOOD_FACTS = "openfoodfacts"
    SOURCE_CHOICES = [(SOURCE_OPEN_FOOD_FACTS, "Open Food Facts")]

    barcode: models.CharField[str, str] = models.CharField(max_length=64, unique=True)
    source: models.CharField[str, str] = models.CharField(
        max_length=32,
        choices=SOURCE_CHOICES,
        default=SOURCE_OPEN_FOOD_FACTS,
    )
    raw_json: models.JSONField[Any, Any] = models.JSONField()
    normalized_name: models.CharField[str, str] = models.CharField(
        max_length=255, blank=True
    )
    brands: models.CharField[str, str] = models.CharField(max_length=255, blank=True)
    nutriments_json: models.JSONField[Any, Any] = models.JSONField(
        blank=True, null=True
    )
    ingredients_text: models.TextField[str, str] = models.TextField(blank=True)
    image_url: models.URLField[str, str] = models.URLField(blank=True)
    image_urls: models.JSONField[Any, Any] = models.JSONField(blank=True, null=True)
    last_fetched_at: models.DateTimeField[datetime, datetime] = models.DateTimeField(
        default=timezone.now
    )
    language: models.CharField[str, str] = models.CharField(max_length=16, blank=True)
    created_at: models.DateTimeField[datetime, datetime] = models.DateTimeField(
        auto_now_add=True
    )
    updated_at: models.DateTimeField[datetime, datetime] = models.DateTimeField(
        auto_now=True
    )

    def __str__(self) -> str:
        return f"{self.barcode} ({self.source})"
