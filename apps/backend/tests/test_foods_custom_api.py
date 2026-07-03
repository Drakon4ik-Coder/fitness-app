from decimal import Decimal

import pytest
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient

from foods.models import FoodItem


def _auth_client(email: str) -> APIClient:
    user = get_user_model().objects.create_user(
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
    return client


def _payload(**overrides: object) -> dict:
    payload: dict = {
        "external_id": "uuid-granola",
        "name": "Mum's granola",
        "brands": "",
        "kcal_100g": "450",
        "protein_g_100g": "12",
        "carbs_g_100g": "55",
        "fat_g_100g": "20",
        "nutriments_json": {"fiber_100g": 8, "iron_100g": 0.004},
    }
    payload.update(overrides)
    return payload


@pytest.mark.django_db
@pytest.mark.integration
def test_create_custom_food_sets_owner_and_source() -> None:
    client = _auth_client("alice@example.com")

    response = client.post("/api/v1/foods/custom", _payload(), format="json")

    assert response.status_code == 200
    assert response.data["source"] == "custom"
    assert response.data["barcode"] is None
    item = FoodItem.objects.get(external_id="uuid-granola")
    assert item.owner is not None
    assert item.owner.email == "alice@example.com"
    assert item.nutriments_json == {"fiber_100g": 8, "iron_100g": 0.004}


@pytest.mark.django_db
@pytest.mark.integration
def test_reposting_same_external_id_updates_in_place() -> None:
    client = _auth_client("alice@example.com")
    assert (
        client.post("/api/v1/foods/custom", _payload(), format="json").status_code
        == 200
    )

    response = client.post(
        "/api/v1/foods/custom",
        _payload(name="Mum's granola v2", kcal_100g="430"),
        format="json",
    )

    assert response.status_code == 200
    assert FoodItem.objects.count() == 1
    item = FoodItem.objects.get(external_id="uuid-granola")
    assert item.name == "Mum's granola v2"
    assert item.kcal_100g == Decimal("430")


@pytest.mark.django_db
@pytest.mark.integration
def test_cannot_touch_another_users_custom_food() -> None:
    alice = _auth_client("alice@example.com")
    bob = _auth_client("bob@example.com")
    assert (
        alice.post("/api/v1/foods/custom", _payload(), format="json").status_code == 200
    )

    response = bob.post(
        "/api/v1/foods/custom", _payload(name="Hijacked"), format="json"
    )

    assert response.status_code == 400
    assert FoodItem.objects.get(external_id="uuid-granola").name == "Mum's granola"


@pytest.mark.django_db
@pytest.mark.integration
def test_macro_bounds_are_validated() -> None:
    client = _auth_client("alice@example.com")

    too_dense = client.post(
        "/api/v1/foods/custom", _payload(protein_g_100g="120"), format="json"
    )
    too_caloric = client.post(
        "/api/v1/foods/custom", _payload(kcal_100g="1200"), format="json"
    )

    assert too_dense.status_code == 400
    assert too_caloric.status_code == 400
    assert FoodItem.objects.count() == 0


@pytest.mark.django_db
@pytest.mark.integration
def test_typeahead_scopes_custom_foods_to_owner() -> None:
    alice = _auth_client("alice@example.com")
    bob = _auth_client("bob@example.com")
    assert (
        alice.post("/api/v1/foods/custom", _payload(), format="json").status_code == 200
    )
    FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="123",
        barcode="123",
        name="Granola bar (global)",
        raw_source_json={},
    )

    alice_names = {
        row["name"]
        for row in alice.get("/api/v1/foods/typeahead", {"q": "granola"}).data
    }
    bob_names = {
        row["name"] for row in bob.get("/api/v1/foods/typeahead", {"q": "granola"}).data
    }

    assert alice_names == {"Mum's granola", "Granola bar (global)"}
    assert bob_names == {"Granola bar (global)"}

    # The compact rows carry source/external_id so the client can tell its
    # own custom foods apart from catalog items.
    custom_row = next(
        row
        for row in alice.get("/api/v1/foods/typeahead", {"q": "granola"}).data
        if row["name"] == "Mum's granola"
    )
    assert custom_row["source"] == "custom"
    assert custom_row["external_id"] == "uuid-granola"


@pytest.mark.django_db
@pytest.mark.integration
def test_ingest_rejects_custom_source() -> None:
    client = _auth_client("alice@example.com")

    response = client.post(
        "/api/v1/foods/ingest",
        {
            "source": "custom",
            "external_id": "uuid-granola",
            "barcode": "",
            "name": "Forged overwrite",
            "raw_source_json": {},
        },
        format="json",
    )

    assert response.status_code == 400
