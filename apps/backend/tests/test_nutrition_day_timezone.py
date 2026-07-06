from datetime import datetime
from datetime import timezone as dt_timezone
from decimal import Decimal

import pytest
from django.core.cache import cache
from rest_framework.test import APIClient

from accounts.models import User
from foods.models import FoodItem
from nutrition.models import MealEntry


@pytest.fixture(autouse=True)
def _clear_cache():
    cache.clear()
    yield
    cache.clear()


def _auth_client(email: str = "tzday@example.com") -> tuple[APIClient, User]:
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


@pytest.mark.django_db
@pytest.mark.integration
def test_day_grouped_by_user_local_date() -> None:
    client, user = _auth_client()
    user.timezone = "Asia/Tokyo"  # UTC+9
    user.save(update_fields=["timezone"])

    food = FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="tzd-1",
        barcode="tzd-1",
        name="TZ Day Food",
        kcal_100g=Decimal("100"),
        raw_source_json={"product": {"product_name": "TZ Day Food"}},
    )
    # 15:30 UTC on Jun 1 == 00:30 Tokyo on Jun 2.
    MealEntry.objects.create(
        user=user,
        food_item=food,
        meal_type=MealEntry.MEAL_DINNER,
        consumed_at=datetime(2026, 6, 1, 15, 30, tzinfo=dt_timezone.utc),
        quantity_g=Decimal("100"),
    )

    # Under the user's zone the entry belongs to Jun 2, not Jun 1 (UTC).
    jun2 = client.get("/api/v1/nutrition/day", {"date": "2026-06-02"})
    assert len(jun2.data["meals"]["dinner"]) == 1

    jun1 = client.get("/api/v1/nutrition/day", {"date": "2026-06-01"})
    assert len(jun1.data["meals"]["dinner"]) == 0


@pytest.mark.django_db
@pytest.mark.integration
def test_me_patch_sets_timezone_and_rejects_unknown() -> None:
    client, _ = _auth_client("tzpatch@example.com")

    ok = client.patch("/api/v1/auth/me", {"timezone": "Europe/Kyiv"}, format="json")
    assert ok.status_code == 200
    assert ok.data["timezone"] == "Europe/Kyiv"

    bad = client.patch("/api/v1/auth/me", {"timezone": "Mars/Olympus"}, format="json")
    assert bad.status_code == 400
