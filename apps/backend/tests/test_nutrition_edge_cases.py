"""Edge and failure paths of the nutrition and preferences apps (KAN-131)."""

from datetime import timedelta
from decimal import Decimal

import pytest
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.utils import timezone
from rest_framework.test import APIClient

from foods.models import FoodItem
from nutrients.catalog import NUTRIENT_CATALOG
from nutrition.models import MealEntry
from nutrition.utils import nutrient_per_100g

PASSWORD = "Str0ngPass!word"


@pytest.fixture(autouse=True)
def _clean_cache():
    cache.clear()
    yield
    cache.clear()


def _client(email: str = "nutedge@example.com"):
    user = get_user_model().objects.create_user(
        email=email, password=PASSWORD, email_verified=True
    )
    client = APIClient()
    token = client.post(
        "/api/v1/auth/token", {"email": email, "password": PASSWORD}, format="json"
    )
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token.data['access']}")
    return client, user


def _food() -> FoodItem:
    return FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="ne-1",
        barcode="ne-1",
        name="Rice",
        kcal_100g=Decimal("130"),
        raw_source_json={},
    )


def _entry(user, food, **extra) -> MealEntry:
    return MealEntry.objects.create(
        user=user,
        food_item=food,
        meal_type=MealEntry.MEAL_LUNCH,
        consumed_at=extra.pop("consumed_at", timezone.now()),
        quantity_g=Decimal("100"),
        **extra,
    )


@pytest.mark.django_db
@pytest.mark.integration
def test_unknown_stored_timezone_falls_back_to_utc() -> None:
    # The serializer rejects unknown zones, but rows written before that
    # validation (or by hand) must not 500 the day view.
    client, user = _client()
    get_user_model().objects.filter(pk=user.pk).update(timezone="Mars/Olympus")
    response = client.get("/api/v1/nutrition/day")
    assert response.status_code == 200
    assert str(response.data["date"]) == timezone.now().date().isoformat()


@pytest.mark.django_db
@pytest.mark.integration
def test_day_rejects_a_malformed_date() -> None:
    client, _ = _client("baddate@example.com")
    response = client.get("/api/v1/nutrition/day", {"date": "2026-13-45"})
    assert response.status_code == 400


@pytest.mark.django_db
@pytest.mark.integration
def test_offline_delete_rejects_a_malformed_mutation_time() -> None:
    client, user = _client("baddelete@example.com")
    entry = _entry(user, _food())
    response = client.delete(
        f"/api/v1/nutrition/entries/{entry.pk}?client_updated_at=yesterday"
    )
    assert response.status_code == 400
    entry.refresh_from_db()
    assert entry.deleted_at is None


@pytest.mark.django_db
@pytest.mark.integration
def test_offline_delete_treats_a_naive_mutation_time_as_utc() -> None:
    client, user = _client("naivedelete@example.com")
    entry = _entry(user, _food())
    # Naive and older than the entry's last change: the newer edit wins and the
    # replayed delete is dropped (still 204 so the client clears the op).
    stale = (timezone.now() - timedelta(hours=1)).replace(tzinfo=None)
    response = client.delete(
        f"/api/v1/nutrition/entries/{entry.pk}?client_updated_at={stale.isoformat()}"
    )
    assert response.status_code == 204
    entry.refresh_from_db()
    assert entry.deleted_at is None


@pytest.mark.django_db
@pytest.mark.integration
def test_resurrecting_create_can_move_the_entry_in_time() -> None:
    client, user = _client("resurrect@example.com")
    food = _food()
    entry = _entry(user, food)
    entry.deleted_at = timezone.now() - timedelta(minutes=1)
    entry.updated_at = timezone.now() - timedelta(minutes=1)
    entry.save()
    new_time = timezone.now() - timedelta(hours=3)

    response = client.post(
        "/api/v1/nutrition/entries",
        {
            "food_item_id": food.id,
            "meal_type": "dinner",
            "quantity_g": "80",
            "consumed_at": new_time.isoformat(),
            "client_uuid": str(entry.client_uuid),
            "client_updated_at": (entry.updated_at + timedelta(seconds=5)).isoformat(),
        },
        format="json",
    )
    assert response.status_code == 200
    entry.refresh_from_db()
    assert entry.deleted_at is None
    assert entry.consumed_at == new_time


@pytest.mark.django_db
@pytest.mark.integration
def test_sync_accepts_a_naive_cursor_and_clamps_a_bad_limit() -> None:
    client, user = _client("synccursor@example.com")
    _entry(user, _food())
    naive_since = (timezone.now() - timedelta(days=1)).replace(tzinfo=None)
    response = client.get(
        "/api/v1/nutrition/entries/sync",
        {"since": f"{naive_since.isoformat()}|0", "limit": "many"},
    )
    assert response.status_code == 200
    assert len(response.data["entries"]) == 1


def test_unparseable_nutrient_values_read_as_missing() -> None:
    spec = NUTRIENT_CATALOG[0]
    assert nutrient_per_100g(spec, {f"{spec.off_key}_100g": "lots"}) is None
    assert nutrient_per_100g(spec, {f"{spec.off_key}_100g": [1, 2]}) is None


@pytest.mark.django_db
@pytest.mark.integration
@pytest.mark.parametrize(
    "goals",
    [["protein", 150], {"protein": "150"}, {"protein": True}],
)
def test_preferences_reject_malformed_nutrient_goals(goals: object) -> None:
    client, _ = _client("badgoals@example.com")
    response = client.patch(
        "/api/v1/preferences/", {"nutrient_goals": goals}, format="json"
    )
    assert response.status_code == 400
