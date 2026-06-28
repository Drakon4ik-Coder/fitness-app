from datetime import datetime, timedelta, timezone as dt_timezone
from decimal import Decimal

import pytest
from django.core.cache import cache
from rest_framework.test import APIClient

from accounts.models import User
from foods.models import FoodItem
from nutrition.models import MealEntry


def _auth_client(email: str = "mtcache@example.com") -> tuple[APIClient, User]:
    user = User.objects.create_user(
        email=email,
        password="Str0ngPass!word",
        email_verified=True,
    )
    client = APIClient()
    token = client.post(
        "/api/v1/auth/token",
        {"email": user.email, "password": "Str0ngPass!word"},
        format="json",
    )
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token.data['access']}")
    return client, user


def _food() -> FoodItem:
    return FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="mtc-1",
        barcode="mtc-1",
        name="MTC Food",
        kcal_100g=Decimal("100"),
        raw_source_json={"product": {"product_name": "MTC Food"}},
    )


@pytest.fixture(autouse=True)
def _clear_meal_times_cache():
    # The test DB rolls back and reuses user IDs, so the per-user cache key can
    # collide across tests; clear it for isolation.
    cache.clear()
    yield
    cache.clear()


def _log_lunch(user: User, food: FoodItem, when: datetime) -> None:
    MealEntry.objects.create(
        user=user,
        food_item=food,
        meal_type=MealEntry.MEAL_LUNCH,
        consumed_at=when,
        quantity_g=Decimal("100"),
    )


@pytest.mark.django_db
@pytest.mark.integration
def test_meal_times_cached_until_entry_created() -> None:
    client, user = _auth_client()
    food = _food()
    base = datetime(2026, 6, 1, 13, 0, tzinfo=dt_timezone.utc)

    for day in range(5):
        _log_lunch(user, food, base + timedelta(days=day))

    # First fetch computes and caches (5 samples).
    first = client.get("/api/v1/nutrition/meal-times")
    assert first.data["meal_times"]["lunch"]["sample_count"] == 5

    # A direct ORM insert bypasses the view, so it does NOT bust the cache.
    _log_lunch(user, food, base + timedelta(days=5))
    cached = client.get("/api/v1/nutrition/meal-times")
    assert cached.data["meal_times"]["lunch"]["sample_count"] == 5

    # Creating an entry through the API invalidates the cache...
    create = client.post(
        "/api/v1/nutrition/entries",
        {
            "food_item_id": food.id,
            "meal_type": MealEntry.MEAL_LUNCH,
            "quantity_g": "100",
            "consumed_at": (base + timedelta(days=6)).isoformat(),
        },
        format="json",
    )
    assert create.status_code == 201

    # ...so the next fetch recomputes (5 ORM + 1 ORM + 1 API = 7).
    fresh = client.get("/api/v1/nutrition/meal-times")
    assert fresh.data["meal_times"]["lunch"]["sample_count"] == 7
