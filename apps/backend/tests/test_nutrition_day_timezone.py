from datetime import date, datetime, timedelta
from datetime import timezone as dt_timezone
from decimal import Decimal
from zoneinfo import ZoneInfo

import pytest
from django.core.cache import cache
from rest_framework.test import APIClient

from accounts.models import User
from foods.models import FoodItem
from nutrition.models import MealEntry
from nutrition.views import _local_day_bounds


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


@pytest.mark.django_db
@pytest.mark.integration
@pytest.mark.parametrize(
    ("day", "inside_utc", "outside_utc"),
    [
        # Spring forward (23h day): local Mar 29 ends at 23:00 UTC, so 22:30 UTC
        # is still Mar 29 (23:30 BST) while 23:30 UTC is already Mar 30.
        (
            "2026-03-29",
            datetime(2026, 3, 29, 22, 30, tzinfo=dt_timezone.utc),
            datetime(2026, 3, 29, 23, 30, tzinfo=dt_timezone.utc),
        ),
        # Fall back (25h day): local Oct 25 starts at 23:00 UTC the day before,
        # so 23:30 UTC Oct 24 (00:30 BST) already belongs to Oct 25.
        (
            "2026-10-25",
            datetime(2026, 10, 24, 23, 30, tzinfo=dt_timezone.utc),
            datetime(2026, 10, 24, 22, 30, tzinfo=dt_timezone.utc),
        ),
        # ...and it ends 25h later at 00:00 UTC Oct 26 (midnight GMT), so 23:30
        # UTC Oct 25 is still Oct 25 — a `start + 24h` end bound would lose it.
        (
            "2026-10-25",
            datetime(2026, 10, 25, 23, 30, tzinfo=dt_timezone.utc),
            datetime(2026, 10, 26, 0, 30, tzinfo=dt_timezone.utc),
        ),
    ],
)
def test_day_bounds_follow_dst_transitions(
    day: str, inside_utc: datetime, outside_utc: datetime
) -> None:
    # The day log filters on a [local midnight, next local midnight) instant
    # range (KAN-117); on DST days that range is 23 or 25 hours long.
    client, user = _auth_client("tzdst@example.com")
    user.timezone = "Europe/London"
    user.save(update_fields=["timezone"])
    food = FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="tzdst-1",
        barcode="tzdst-1",
        name="DST Food",
        kcal_100g=Decimal("100"),
        raw_source_json={"product": {"product_name": "DST Food"}},
    )
    for when in (inside_utc, outside_utc):
        MealEntry.objects.create(
            user=user,
            food_item=food,
            meal_type=MealEntry.MEAL_DINNER,
            consumed_at=when,
            quantity_g=Decimal("100"),
        )

    response = client.get("/api/v1/nutrition/day", {"date": day})
    assert response.status_code == 200
    dinner = response.data["meals"]["dinner"]
    assert len(dinner) == 1
    assert dinner[0]["consumed_at"].startswith(inside_utc.strftime("%Y-%m-%dT%H:%M"))


@pytest.mark.parametrize(
    ("zone_name", "day"),
    [
        # DST transitions *at local midnight*: the day's first instant is in a
        # gap (spring forward) or its last hour repeats (fall back).
        ("America/Sao_Paulo", date(2018, 11, 4)),  # 00:00 -> 01:00, 23h day
        ("America/Sao_Paulo", date(2019, 2, 16)),  # 00:00 -> 23:00, 25h day
        ("America/Santiago", date(2023, 4, 1)),  # fall back at midnight
        ("America/Santiago", date(2024, 9, 8)),  # spring forward at midnight
        ("America/Asuncion", date(2023, 10, 1)),  # spring forward at midnight
        # Transitions away from midnight, plus a no-DST control.
        ("Europe/London", date(2026, 3, 29)),
        ("Europe/London", date(2026, 10, 25)),
        ("Asia/Tokyo", date(2026, 6, 1)),
    ],
)
def test_local_day_bounds_match_local_calendar_day(zone_name: str, day: date) -> None:
    # Property check (KAN-117 review): an instant is inside [start, end) exactly
    # when its wall-clock date in the zone is `day`. Probed every 15 minutes
    # across the surrounding three days.
    zone = ZoneInfo(zone_name)
    start, end = _local_day_bounds(day, zone)
    probe = datetime.combine(
        day - timedelta(days=1), datetime.min.time(), dt_timezone.utc
    )
    stop = probe + timedelta(days=3)
    while probe < stop:
        on_day = probe.astimezone(zone).date() == day
        assert on_day == (start <= probe < end), (zone_name, day, probe)
        probe += timedelta(minutes=15)


@pytest.mark.django_db
@pytest.mark.integration
@pytest.mark.parametrize("day", ["0001-01-01", "9999-12-31"])
def test_day_rejects_dates_whose_bounds_overflow(day: str) -> None:
    client, user = _auth_client("tzedge@example.com")
    user.timezone = "Asia/Tokyo"
    user.save(update_fields=["timezone"])
    response = client.get("/api/v1/nutrition/day", {"date": day})
    assert response.status_code == 400
