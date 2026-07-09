"""KAN-28 offline writes & multi-device sync: delta feed, idempotent create
replay, LWW conflict resolution, uuid addressing, and tombstone propagation."""

import uuid
from datetime import timedelta
from decimal import Decimal
from urllib.parse import quote

import pytest
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import User
from foods.models import FoodItem
from nutrition.models import MealEntry


def _auth_client(email: str = "syncuser@example.com") -> tuple[APIClient, User]:
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
    access_token = token_response.data["access"]
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {access_token}")
    return client, user


def _food(external_id: str = "777") -> FoodItem:
    return FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id=external_id,
        barcode=external_id,
        name="Sync Food",
        kcal_100g=Decimal("100"),
        protein_g_100g=Decimal("5"),
        carbs_g_100g=Decimal("10"),
        fat_g_100g=Decimal("2"),
        raw_source_json={"product": {"product_name": "Sync Food"}},
    )


def _entry(user: User, food: FoodItem, **overrides: object) -> MealEntry:
    defaults: dict = {
        "meal_type": MealEntry.MEAL_BREAKFAST,
        "consumed_at": timezone.now(),
        "quantity_g": Decimal("100"),
    }
    defaults.update(overrides)
    return MealEntry.objects.create(user=user, food_item=food, **defaults)


# --- idempotent create replay ---


@pytest.mark.django_db
@pytest.mark.integration
def test_create_with_client_uuid_dedupes_replay() -> None:
    client, _ = _auth_client()
    food = _food()
    entry_uuid = str(uuid.uuid4())
    payload = {
        "food_item_id": food.id,
        "meal_type": "lunch",
        "quantity_g": "150",
        "client_uuid": entry_uuid,
    }

    first = client.post("/api/v1/nutrition/entries", payload, format="json")
    replay = client.post("/api/v1/nutrition/entries", payload, format="json")

    assert first.status_code == 201
    assert replay.status_code == 200
    assert replay.data["id"] == first.data["id"]
    assert MealEntry.objects.filter(client_uuid=entry_uuid).count() == 1


@pytest.mark.django_db
@pytest.mark.integration
def test_create_without_client_uuid_still_works() -> None:
    client, _ = _auth_client()
    food = _food()

    response = client.post(
        "/api/v1/nutrition/entries",
        {"food_item_id": food.id, "meal_type": "dinner", "quantity_g": "80"},
        format="json",
    )

    assert response.status_code == 201
    # Server mints a uuid so the entry can still sync to other devices.
    assert response.data["client_uuid"]


# --- undo resurrect (KAN-39) ---


@pytest.mark.django_db
@pytest.mark.integration
def test_create_newer_than_tombstone_resurrects_entry() -> None:
    client, user = _auth_client()
    food = _food()
    entry = _entry(user, food, quantity_g=Decimal("120"))
    # Both in the past so the undo's mutation time survives the server clamp.
    entry.deleted_at = timezone.now() - timedelta(minutes=1)
    entry.updated_at = timezone.now() - timedelta(minutes=1)
    entry.save()

    undo_time = entry.updated_at + timedelta(seconds=5)
    response = client.post(
        "/api/v1/nutrition/entries",
        {
            "food_item_id": food.id,
            "meal_type": "lunch",
            "quantity_g": "120",
            "client_uuid": str(entry.client_uuid),
            "client_updated_at": undo_time.isoformat(),
        },
        format="json",
    )

    assert response.status_code == 200
    assert response.data["id"] == entry.id
    entry.refresh_from_db()
    assert entry.deleted_at is None
    assert entry.meal_type == "lunch"
    # The undo's mutation time becomes the LWW basis (clamped to server now).
    assert entry.updated_at == undo_time
    assert MealEntry.objects.filter(client_uuid=entry.client_uuid).count() == 1


@pytest.mark.django_db
@pytest.mark.integration
def test_replayed_create_older_than_tombstone_keeps_delete() -> None:
    """A replayed original create must not undo a newer delete (LWW)."""
    client, user = _auth_client()
    food = _food()
    entry = _entry(user, food)
    entry.deleted_at = timezone.now()
    entry.updated_at = timezone.now()
    entry.save()

    stale_time = entry.updated_at - timedelta(minutes=5)
    for payload_extra in (
        {},  # legacy replay without a mutation time
        {"client_updated_at": stale_time.isoformat()},
    ):
        response = client.post(
            "/api/v1/nutrition/entries",
            {
                "food_item_id": food.id,
                "meal_type": "breakfast",
                "quantity_g": "100",
                "client_uuid": str(entry.client_uuid),
                **payload_extra,
            },
            format="json",
        )
        assert response.status_code == 200
        assert response.data["id"] == entry.id
        entry.refresh_from_db()
        assert entry.deleted_at is not None


@pytest.mark.django_db
@pytest.mark.integration
def test_resurrected_entry_reaches_other_devices_via_delta_feed() -> None:
    client, user = _auth_client()
    food = _food()
    entry = _entry(user, food)
    entry.deleted_at = timezone.now() - timedelta(minutes=1)
    entry.updated_at = timezone.now() - timedelta(minutes=1)
    entry.save()

    cursor = client.get("/api/v1/nutrition/entries/sync").data["next_cursor"]

    undo_time = entry.updated_at + timedelta(seconds=1)
    resurrect = client.post(
        "/api/v1/nutrition/entries",
        {
            "food_item_id": food.id,
            "meal_type": "breakfast",
            "quantity_g": "100",
            "client_uuid": str(entry.client_uuid),
            "client_updated_at": undo_time.isoformat(),
        },
        format="json",
    )
    assert resurrect.status_code == 200

    page = client.get(f"/api/v1/nutrition/entries/sync?since={quote(cursor)}").data
    rows = {row["client_uuid"]: row for row in page["entries"]}
    assert str(entry.client_uuid) in rows
    assert rows[str(entry.client_uuid)]["deleted"] is False


# --- uuid addressing ---


@pytest.mark.django_db
@pytest.mark.integration
def test_patch_and_delete_by_client_uuid() -> None:
    client, user = _auth_client()
    entry = _entry(user, _food())

    patched = client.patch(
        f"/api/v1/nutrition/entries/by-uuid/{entry.client_uuid}",
        {"quantity_g": "222"},
        format="json",
    )
    assert patched.status_code == 200
    entry.refresh_from_db()
    assert entry.quantity_g == Decimal("222.00")

    deleted = client.delete(f"/api/v1/nutrition/entries/by-uuid/{entry.client_uuid}")
    assert deleted.status_code == 204
    entry.refresh_from_db()
    assert entry.deleted_at is not None


@pytest.mark.django_db
@pytest.mark.integration
def test_uuid_routes_scoped_to_owner() -> None:
    _, owner = _auth_client(email="owner-sync@example.com")
    entry = _entry(owner, _food())
    intruder, _ = _auth_client(email="intruder-sync@example.com")

    response = intruder.patch(
        f"/api/v1/nutrition/entries/by-uuid/{entry.client_uuid}",
        {"quantity_g": "1"},
        format="json",
    )

    assert response.status_code == 404


# --- LWW conflict resolution ---


@pytest.mark.django_db
@pytest.mark.integration
def test_stale_offline_edit_loses_to_newer_change() -> None:
    client, user = _auth_client()
    entry = _entry(user, _food(), quantity_g=Decimal("300"))
    # The entry was already changed (e.g. from another device) after the
    # offline edit below was made.
    MealEntry.objects.filter(pk=entry.pk).update(
        updated_at=timezone.now() - timedelta(minutes=5)
    )
    stale_time = timezone.now() - timedelta(hours=1)

    response = client.patch(
        f"/api/v1/nutrition/entries/by-uuid/{entry.client_uuid}",
        {"quantity_g": "50", "client_updated_at": stale_time.isoformat()},
        format="json",
    )

    # Replay succeeds (the client clears its queued op) but the newer state
    # stands — the response carries it so the loser converges.
    assert response.status_code == 200
    assert Decimal(str(response.data["quantity_g"])) == Decimal("300.00")
    entry.refresh_from_db()
    assert entry.quantity_g == Decimal("300.00")


@pytest.mark.django_db
@pytest.mark.integration
def test_newer_offline_edit_wins() -> None:
    client, user = _auth_client()
    entry = _entry(user, _food(), quantity_g=Decimal("300"))
    MealEntry.objects.filter(pk=entry.pk).update(
        updated_at=timezone.now() - timedelta(hours=2)
    )
    edit_time = timezone.now() - timedelta(minutes=10)

    response = client.patch(
        f"/api/v1/nutrition/entries/by-uuid/{entry.client_uuid}",
        {"quantity_g": "50", "client_updated_at": edit_time.isoformat()},
        format="json",
    )

    assert response.status_code == 200
    entry.refresh_from_db()
    assert entry.quantity_g == Decimal("50.00")
    # The mutation keeps its true (client) time so a later edit made elsewhere
    # at T+5min still out-ranks it.
    assert entry.updated_at == edit_time


@pytest.mark.django_db
@pytest.mark.integration
def test_stale_offline_delete_is_dropped() -> None:
    client, user = _auth_client()
    entry = _entry(user, _food())
    MealEntry.objects.filter(pk=entry.pk).update(
        updated_at=timezone.now() - timedelta(minutes=5)
    )
    stale_delete_time = timezone.now() - timedelta(hours=1)

    response = client.delete(
        f"/api/v1/nutrition/entries/by-uuid/{entry.client_uuid}"
        f"?client_updated_at={quote(stale_delete_time.isoformat())}"
    )

    assert response.status_code == 204
    entry.refresh_from_db()
    assert entry.deleted_at is None  # the newer edit won; row survives


@pytest.mark.django_db
@pytest.mark.integration
def test_edit_after_delete_is_rejected() -> None:
    client, user = _auth_client()
    entry = _entry(user, _food())
    client.delete(f"/api/v1/nutrition/entries/{entry.id}")

    response = client.patch(
        f"/api/v1/nutrition/entries/{entry.id}",
        {"quantity_g": "120"},
        format="json",
    )

    assert response.status_code == 404


@pytest.mark.django_db
@pytest.mark.integration
def test_delete_replay_is_idempotent() -> None:
    client, user = _auth_client()
    entry = _entry(user, _food())

    first = client.delete(f"/api/v1/nutrition/entries/{entry.id}")
    replay = client.delete(f"/api/v1/nutrition/entries/{entry.id}")

    assert first.status_code == 204
    assert replay.status_code == 204


# --- delta feed ---


@pytest.mark.django_db
@pytest.mark.integration
def test_sync_bootstrap_returns_cursor_only() -> None:
    client, user = _auth_client()
    _entry(user, _food())

    response = client.get("/api/v1/nutrition/entries/sync")

    assert response.status_code == 200
    assert response.data["entries"] == []
    assert response.data["has_more"] is False
    assert "|" in response.data["next_cursor"]


@pytest.mark.django_db
@pytest.mark.integration
def test_sync_delivers_changes_after_cursor_including_tombstones() -> None:
    client, user = _auth_client()
    food = _food()
    cursor = client.get("/api/v1/nutrition/entries/sync").data["next_cursor"]

    created = client.post(
        "/api/v1/nutrition/entries",
        {"food_item_id": food.id, "meal_type": "lunch", "quantity_g": "90"},
        format="json",
    )
    other = _entry(user, food)
    client.delete(f"/api/v1/nutrition/entries/{other.id}")

    page = client.get(f"/api/v1/nutrition/entries/sync?since={quote(cursor)}")

    assert page.status_code == 200
    by_uuid = {e["client_uuid"]: e for e in page.data["entries"]}
    assert by_uuid[created.data["client_uuid"]]["deleted"] is False
    assert by_uuid[str(other.client_uuid)]["deleted"] is True
    assert page.data["has_more"] is False

    # The advanced cursor yields nothing new — the feed converged.
    again = client.get(
        f"/api/v1/nutrition/entries/sync?since={quote(page.data['next_cursor'])}"
    )
    assert again.data["entries"] == []


@pytest.mark.django_db
@pytest.mark.integration
def test_sync_paginates_with_stable_cursor() -> None:
    client, user = _auth_client()
    food = _food()
    cursor = client.get("/api/v1/nutrition/entries/sync").data["next_cursor"]
    entries = [_entry(user, food) for _ in range(5)]

    seen: list[str] = []
    for _ in range(10):
        page = client.get(
            f"/api/v1/nutrition/entries/sync?since={quote(cursor)}&limit=2"
        )
        seen.extend(e["client_uuid"] for e in page.data["entries"])
        cursor = page.data["next_cursor"]
        if not page.data["has_more"]:
            break

    assert sorted(seen) == sorted(str(e.client_uuid) for e in entries)
    assert len(seen) == len(set(seen))  # no duplicates across pages


@pytest.mark.django_db
@pytest.mark.integration
def test_sync_scoped_to_user() -> None:
    other_client, other_user = _auth_client(email="other-sync@example.com")
    _entry(other_user, _food("888"))
    client, _ = _auth_client()
    cursor = "1970-01-01T00:00:00+00:00|0"

    page = client.get(f"/api/v1/nutrition/entries/sync?since={quote(cursor)}")

    assert page.data["entries"] == []


@pytest.mark.django_db
@pytest.mark.integration
def test_sync_rejects_invalid_cursor() -> None:
    client, _ = _auth_client()

    response = client.get("/api/v1/nutrition/entries/sync?since=garbage")

    assert response.status_code == 400
