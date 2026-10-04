"""Behavior the first mutmut run showed no test pinned (KAN-130).

Each test kills one or more surviving mutants in nutrition/views.py or
nutrition/utils.py. Survivors judged equivalent (no observable change) are
listed in the KAN-130 PR rather than tested.
"""

from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import User
from foods.models import FoodItem
from nutrition.models import MealEntry
from nutrition.utils import serialize_decimal, summarize_meal_time
from nutrition.views import compute_meal_times


def _user(email: str) -> User:
    return User.objects.create_user(
        email=email, password="Str0ngPass!word", email_verified=True
    )


def _client(user: User) -> APIClient:
    client = APIClient()
    token = client.post(
        "/api/v1/auth/token",
        {"email": user.email, "password": "Str0ngPass!word"},
        format="json",
    )
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token.data['access']}")
    return client


def _food() -> FoodItem:
    return FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="mg-1",
        barcode="mg-1",
        name="MG Food",
        kcal_100g=Decimal("100"),
        raw_source_json={},
    )


def _log(user: User, food: FoodItem, meal: str, when: datetime) -> MealEntry:
    return MealEntry.objects.create(
        user=user,
        food_item=food,
        meal_type=meal,
        consumed_at=when,
        quantity_g=Decimal("100"),
    )


def _recent_days(count: int) -> list[datetime]:
    # Relative to now: compute_meal_times only looks back a fixed window
    # (KAN-116 was a fixed-date fixture that aged out of it).
    today = timezone.now().replace(hour=0, minute=0, second=0, microsecond=0)
    return [today - timedelta(days=day) for day in range(1, count + 1)]


# --- summarize_meal_time ---------------------------------------------------


def test_odd_sample_iqr_excludes_the_median() -> None:
    # lower [8, 9] -> 8.5, upper [11, 14] -> 12.5: IQR 4, half width 2.
    summary = summarize_meal_time([8.0, 9.0, 10.0, 11.0, 14.0])
    assert summary == {"typical_hour": 10.0, "half_width": 2.0, "sample_count": 5}


def test_even_sample_median_and_iqr_round_to_two_places() -> None:
    third = 1.0 / 3.0
    # Median (7.333 + 8) / 2 = 7.667; lower [6, 7.333] -> 6.667,
    # upper [8, 10] -> 9: IQR 2.333, half width 1.1667.
    summary = summarize_meal_time([6.0, 7.0 + third, 8.0, 10.0])
    assert summary == {"typical_hour": 7.67, "half_width": 1.17, "sample_count": 4}


def test_hours_are_cut_at_the_largest_gap() -> None:
    # Gaps 6, 6, 6.5 and a 5.5h wrap gap: the cut goes after 12.0, so the run
    # is 18.5, 24, 30, 36 and the median 27 wraps to 03:00.
    summary = summarize_meal_time([0.0, 6.0, 12.0, 18.5])
    assert summary is not None
    assert summary["typical_hour"] == 3.0


def test_tied_gaps_keep_the_plain_order() -> None:
    # Every gap (wrap included) is 6h: no gap is strictly larger, so the
    # hours are not re-anchored and the median stays 9.
    summary = summarize_meal_time([0.0, 6.0, 12.0, 18.0])
    assert summary is not None
    assert summary["typical_hour"] == 9.0


# --- serialize_decimal ------------------------------------------------------


def test_serialize_decimal_rounds_half_up() -> None:
    # Banker's rounding (Decimal's default) would give 0.12.
    assert serialize_decimal(Decimal("0.125")) == 0.13


# --- compute_meal_times -----------------------------------------------------


@pytest.mark.django_db
def test_meal_times_use_only_this_users_main_meals_with_minutes() -> None:
    me = _user("me@example.com")
    other = _user("other@example.com")
    food = _food()
    for day in _recent_days(4):
        _log(me, food, MealEntry.MEAL_LUNCH, day.replace(hour=12, minute=30))
        # Another user's late lunches must not shift my typical hour.
        _log(other, food, MealEntry.MEAL_LUNCH, day.replace(hour=18))
        # Snacks are not a learnable meal window.
        _log(me, food, MealEntry.MEAL_SNACKS, day.replace(hour=16))

    meal_times = compute_meal_times(me.pk, UTC)

    assert set(meal_times) == {MealEntry.MEAL_LUNCH}
    assert meal_times[MealEntry.MEAL_LUNCH]["typical_hour"] == 12.5


# --- entry lookup by client uuid -------------------------------------------


@pytest.mark.django_db
@pytest.mark.integration
def test_uuid_patch_edits_exactly_that_entry() -> None:
    me = _user("uuid@example.com")
    client = _client(me)
    food = _food()
    now = timezone.now()
    first = _log(me, food, MealEntry.MEAL_LUNCH, now - timedelta(hours=2))
    second = _log(me, food, MealEntry.MEAL_LUNCH, now - timedelta(hours=1))

    response = client.patch(
        f"/api/v1/nutrition/entries/by-uuid/{second.client_uuid}",
        {"quantity_g": 50},
        format="json",
    )

    assert response.status_code == 200
    first.refresh_from_db()
    second.refresh_from_db()
    assert second.quantity_g == Decimal("50")
    assert first.quantity_g == Decimal("100")
