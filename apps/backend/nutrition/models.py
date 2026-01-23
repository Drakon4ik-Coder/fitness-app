from django.conf import settings
from django.db import models
from django.utils import timezone

from foods.models import FoodItem


class MealEntry(models.Model):
    MEAL_BREAKFAST = "breakfast"
    MEAL_LUNCH = "lunch"
    MEAL_DINNER = "dinner"
    MEAL_SNACKS = "snacks"
    MEAL_TYPE_CHOICES = [
        (MEAL_BREAKFAST, "Breakfast"),
        (MEAL_LUNCH, "Lunch"),
        (MEAL_DINNER, "Dinner"),
        (MEAL_SNACKS, "Snacks"),
    ]

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="meal_entries",
    )
    food_item = models.ForeignKey(
        FoodItem,
        on_delete=models.CASCADE,
        related_name="meal_entries",
    )
    meal_type = models.CharField(
        max_length=16, choices=MEAL_TYPE_CHOICES, default=MEAL_BREAKFAST
    )
    consumed_at = models.DateTimeField(default=timezone.now)
    quantity_g = models.DecimalField(max_digits=8, decimal_places=2)

    def __str__(self) -> str:
        return f"{self.user_id} {self.meal_type} {self.food_item_id}"
