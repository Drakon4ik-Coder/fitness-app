import pytest
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient

from foods.models import FoodEditProposal, FoodItem


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


def _global_mince() -> FoodItem:
    return FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="5054070875254",
        barcode="5054070875254",
        name="Lean Beef Steak Mince",
        raw_source_json={},
        kcal_100g="172",
        protein_g_100g="29",
        fat_g_100g="6.3",
    )


def _override_payload(global_id: int, **overrides: object) -> dict:
    payload: dict = {
        "external_id": "cf-override-1",
        "name": "Lean Beef Steak Mince (corrected)",
        "kcal_100g": "124",
        "protein_g_100g": "21",
        "fat_g_100g": "4.5",
        "overrides_food": global_id,
    }
    payload.update(overrides)
    return payload


@pytest.mark.django_db
@pytest.mark.integration
def test_override_creates_shadow_and_captures_proposal() -> None:
    client = _auth_client("alice@example.com")
    target = _global_mince()

    response = client.post(
        "/api/v1/foods/custom", _override_payload(target.id), format="json"
    )

    assert response.status_code == 200
    assert response.data["overrides_food"] == target.id
    override = FoodItem.objects.get(external_id="cf-override-1")
    assert override.overrides_id == target.id

    proposal = FoodEditProposal.objects.get()
    assert proposal.food_item_id == target.id
    assert proposal.status == FoodEditProposal.STATUS_PENDING
    assert proposal.old_values["kcal_100g"] == 172.0
    assert proposal.new_values["kcal_100g"] == 124.0
    assert proposal.old_values["protein_g_100g"] == 29.0
    assert proposal.new_values["protein_g_100g"] == 21.0


@pytest.mark.django_db
@pytest.mark.integration
def test_each_override_save_appends_a_proposal() -> None:
    client = _auth_client("alice@example.com")
    target = _global_mince()
    client.post("/api/v1/foods/custom", _override_payload(target.id), format="json")

    client.post(
        "/api/v1/foods/custom",
        _override_payload(target.id, kcal_100g="126"),
        format="json",
    )

    assert FoodEditProposal.objects.count() == 2
    latest = FoodEditProposal.objects.order_by("-id").first()
    assert latest is not None
    assert latest.new_values["kcal_100g"] == 126.0


@pytest.mark.django_db
@pytest.mark.integration
def test_partial_reupsert_keeps_stored_nutrients_in_the_proposal() -> None:
    client = _auth_client("alice@example.com")
    target = _global_mince()
    client.post("/api/v1/foods/custom", _override_payload(target.id), format="json")

    # Required fields only: omitting a nutrient means "unchanged", not "gone".
    # The proposal must snapshot the override's stored state, or this save
    # would retract alice's protein/fat votes from convergence.
    response = client.post(
        "/api/v1/foods/custom",
        {
            "external_id": "cf-override-1",
            "name": "Lean Beef Steak Mince (corrected)",
            "kcal_100g": "124",
        },
        format="json",
    )

    assert response.status_code == 200
    latest = FoodEditProposal.objects.order_by("-id").first()
    assert latest is not None
    assert latest.new_values["kcal_100g"] == 124.0
    assert latest.new_values["protein_g_100g"] == 21.0
    assert latest.new_values["fat_g_100g"] == 4.5


@pytest.mark.django_db
@pytest.mark.integration
def test_explicit_null_detaches_the_override() -> None:
    client = _auth_client("alice@example.com")
    target = _global_mince()
    client.post("/api/v1/foods/custom", _override_payload(target.id), format="json")

    response = client.post(
        "/api/v1/foods/custom",
        _override_payload(target.id, overrides_food=None),
        format="json",
    )

    assert response.status_code == 200
    assert response.data["overrides_food"] is None
    override = FoodItem.objects.get(external_id="cf-override-1")
    assert override.overrides_id is None
    # Detached foods stop feeding convergence evidence to the old target.
    assert FoodEditProposal.objects.count() == 1


@pytest.mark.django_db
@pytest.mark.integration
def test_omitting_overrides_food_keeps_the_link() -> None:
    client = _auth_client("alice@example.com")
    target = _global_mince()
    client.post("/api/v1/foods/custom", _override_payload(target.id), format="json")

    payload = _override_payload(target.id, kcal_100g="126")
    del payload["overrides_food"]
    response = client.post("/api/v1/foods/custom", payload, format="json")

    assert response.status_code == 200
    assert response.data["overrides_food"] == target.id
    override = FoodItem.objects.get(external_id="cf-override-1")
    assert override.overrides_id == target.id
    assert FoodEditProposal.objects.count() == 2


@pytest.mark.django_db
@pytest.mark.integration
def test_override_target_must_be_global() -> None:
    alice = _auth_client("alice@example.com")
    own = alice.post(
        "/api/v1/foods/custom",
        {"external_id": "cf-own", "name": "Own", "kcal_100g": "100"},
        format="json",
    )

    response = alice.post(
        "/api/v1/foods/custom",
        _override_payload(own.data["id"], external_id="cf-override-bad"),
        format="json",
    )

    assert response.status_code == 400
    response = alice.post(
        "/api/v1/foods/custom",
        _override_payload(999999, external_id="cf-override-bad"),
        format="json",
    )
    assert response.status_code == 400


@pytest.mark.django_db
@pytest.mark.integration
def test_typeahead_swaps_global_for_the_owners_override_only() -> None:
    alice = _auth_client("alice@example.com")
    bob = _auth_client("bob@example.com")
    target = _global_mince()
    alice.post("/api/v1/foods/custom", _override_payload(target.id), format="json")

    alice_names = {
        row["name"] for row in alice.get("/api/v1/foods/typeahead", {"q": "mince"}).data
    }
    bob_names = {
        row["name"] for row in bob.get("/api/v1/foods/typeahead", {"q": "mince"}).data
    }

    assert alice_names == {"Lean Beef Steak Mince (corrected)"}
    assert bob_names == {"Lean Beef Steak Mince"}


@pytest.mark.django_db
@pytest.mark.integration
def test_deleting_the_override_restores_the_global_item() -> None:
    alice = _auth_client("alice@example.com")
    target = _global_mince()
    created = alice.post(
        "/api/v1/foods/custom", _override_payload(target.id), format="json"
    )

    assert alice.delete(f"/api/v1/foods/custom/{created.data['id']}").status_code == 204

    names = {
        row["name"] for row in alice.get("/api/v1/foods/typeahead", {"q": "mince"}).data
    }
    assert names == {"Lean Beef Steak Mince"}
