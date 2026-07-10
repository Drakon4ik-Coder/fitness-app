from datetime import datetime, timedelta
from datetime import timezone as dt_timezone
from decimal import Decimal

import pytest
from django.core.cache import cache
from rest_framework.test import APIClient

from accounts.models import User
from foods.models import FoodItem
from nutrition.models import MealEntry
from nutrition.utils import summarize_meal_time


@pytest.fixture(autouse=True)
def _clear_meal_times_cache():
    # The test DB rolls back and reuses user IDs, so the per-user cache key can
    # collide across tests; clear it for isolation.
    cache.clear()
    yield
    cache.clear()


def _auth_client(email: str = "mealtimes@example.com") -> tuple[APIClient, User]:
    user = User.objects.create_user(
        email=email,
        password="Str0ngPass!word",
        email_verified=True,
    )
    client = APIClient()
    token_response = client.post(
        "/api/v1/auth/token",
        {"email": user.email, "password": "Str0ngPass!word"},
        format="json",
    )
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token_response.data['access']}")
    return client, user


def _food() -> FoodItem:
    return FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="mt-1",
        barcode="mt-1",
        name="MT Food",
        kcal_100g=Decimal("100"),
        raw_source_json={"product": {"product_name": "MT Food"}},
    )


def _log(user: User, food: FoodItem, meal: str, when: datetime) -> None:
    MealEntry.objects.create(
        user=user,
        food_item=food,
        meal_type=meal,
        consumed_at=when,
        quantity_g=Decimal("100"),
    )


@pytest.mark.django_db
@pytest.mark.integration
def test_meal_times_learns_typical_hour() -> None:
    client, user = _auth_client()
    food = _food()
    base = datetime(2026, 6, 1, 0, 0, tzinfo=dt_timezone.utc)

    # Five lunches clustered around 13:00 (12:30, 13:00, 13:00, 13:30, 14:00).
    for day, hour, minute in [
        (1, 12, 30),
        (2, 13, 0),
        (3, 13, 0),
        (4, 13, 30),
        (5, 14, 0),
    ]:
        _log(
            user,
            food,
            MealEntry.MEAL_LUNCH,
            base + timedelta(days=day, hours=hour, minutes=minute),
        )

    response = client.get("/api/v1/nutrition/meal-times")
    assert response.status_code == 200
    meal_times = response.data["meal_times"]
    assert "lunch" in meal_times
    assert meal_times["lunch"]["typical_hour"] == pytest.approx(13.0, abs=0.01)
    assert meal_times["lunch"]["sample_count"] == 5
    assert 1.0 <= meal_times["lunch"]["half_width"] <= 3.0
    # Breakfast/dinner have no history, so they are omitted (client uses defaults).
    assert "breakfast" not in meal_times
    assert "dinner" not in meal_times


@pytest.mark.django_db
@pytest.mark.integration
def test_meal_times_ignores_sparse_meals() -> None:
    client, user = _auth_client("sparse@example.com")
    food = _food()
    base = datetime(2026, 6, 1, 8, 0, tzinfo=dt_timezone.utc)

    # Only three breakfasts — below the MIN_MEAL_SAMPLES threshold.
    for day in range(3):
        _log(user, food, MealEntry.MEAL_BREAKFAST, base + timedelta(days=day))

    response = client.get("/api/v1/nutrition/meal-times")
    assert response.status_code == 200
    assert response.data["meal_times"] == {}


@pytest.mark.django_db
@pytest.mark.integration
def test_meal_times_converts_to_user_timezone() -> None:
    client, user = _auth_client("tzuser@example.com")
    user.timezone = "Asia/Tokyo"  # UTC+9, no DST
    user.save(update_fields=["timezone"])
    food = _food()

    # Five lunches logged at 04:00 UTC == 13:00 in Tokyo.
    base = datetime(2026, 6, 1, 4, 0, tzinfo=dt_timezone.utc)
    for day in range(5):
        _log(user, food, MealEntry.MEAL_LUNCH, base + timedelta(days=day))

    response = client.get("/api/v1/nutrition/meal-times")
    assert response.status_code == 200
    lunch = response.data["meal_times"]["lunch"]
    # Converted to the user's zone, the typical hour is 13:00, not 04:00.
    assert lunch["typical_hour"] == pytest.approx(13.0, abs=0.01)


def test_summarize_meal_time_handles_midnight_straddle() -> None:
    # Late dinners around midnight: 23:30, 23:45, 00:15, 00:30. Circularly these
    # cluster at ~00:00; a naive linear median would report ~12:00 (noon).
    summary = summarize_meal_time([23.5, 23.75, 0.25, 0.5])
    assert summary is not None
    typical = summary["typical_hour"]
    assert typical >= 23.5 or typical <= 0.5
    # The spread is ~1h circularly, so the half-width stays at the clamp floor
    # instead of blowing up to the 3h ceiling.
    assert summary["half_width"] == pytest.approx(1.0)


def test_summarize_meal_time_midnight_cluster_median() -> None:
    # Odd sample count so the median is a single sample; 23:00, 23:30, 00:30,
    # 01:00, 01:30 → circular median is 00:30.
    summary = summarize_meal_time([23.0, 23.5, 0.5, 1.0, 1.5])
    assert summary is not None
    assert summary["typical_hour"] == pytest.approx(0.5)


def test_summarize_meal_time_daytime_unaffected_by_unwrap() -> None:
    summary = summarize_meal_time([12.5, 13.0, 13.0, 13.5, 14.0])
    assert summary is not None
    assert summary["typical_hour"] == pytest.approx(13.0)


@pytest.mark.django_db
@pytest.mark.integration
def test_meal_times_excludes_old_entries() -> None:
    client, user = _auth_client("stale@example.com")
    food = _food()
    from django.utils import timezone as dj_tz

    old = dj_tz.now() - timedelta(days=200)
    for day in range(5):
        _log(user, food, MealEntry.MEAL_DINNER, old + timedelta(days=day, hours=19))

    response = client.get("/api/v1/nutrition/meal-times")
    assert response.status_code == 200
    assert "dinner" not in response.data["meal_times"]
