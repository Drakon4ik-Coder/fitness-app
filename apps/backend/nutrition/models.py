import uuid

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
    # Client-generated stable identity (KAN-28). An entry created offline keeps
    # this id across outbox replays, so the server dedupes instead of creating
    # duplicates. Server-generated for rows that predate the field / legacy
    # clients that don't send one.
    client_uuid = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    # Last-write-wins mutation time. Client-supplied on offline replays (the
    # moment the user actually made the change), server "now" otherwise. A write
    # only applies when its mutation time is newer than this. Distinct from
    # synced_at because a replayed offline edit carries a timestamp in the past.
    updated_at = models.DateTimeField(default=timezone.now)
    # Server-monotonic change time driving the delta-sync cursor: set to "now"
    # on every accepted write, so `synced_at > cursor` never misses a change
    # (updated_at can move backwards when an offline edit replays; this can't).
    synced_at = models.DateTimeField(auto_now=True)
    # Soft delete (tombstone). Hard deletes can't propagate to other devices, so
    # a delete keeps the row and other clients drop it when the tombstone syncs.
    deleted_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        # Both the day view (consumed_at__date) and the meal-times stats
        # (consumed_at__gte window per user) filter a user's rows by time, so a
        # composite index turns those into range scans. The synced_at index
        # serves the delta-sync feed (`?since=` per user).
        indexes = [
            models.Index(
                fields=["user", "consumed_at"],
                name="meal_entry_user_time_idx",
            ),
            models.Index(
                fields=["user", "synced_at"],
                name="meal_entry_user_sync_idx",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.user_id} {self.meal_type} {self.food_item_id}"
