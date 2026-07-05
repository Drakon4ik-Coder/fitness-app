from decimal import Decimal

import pytest
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient

from foods.models import FoodEditProposal, FoodItem
from foods.promotion import promote_pending_edits, sweep


def _user(email: str):
    return get_user_model().objects.create_user(
        email=email, password="Str0ngPass!word", email_verified=True
    )


def _auth_client(email: str) -> APIClient:
    user = _user(email)
    client = APIClient()
    token_response = client.post(
        "/api/v1/auth/token",
        {"email": user.email, "password": "Str0ngPass!word"},
        format="json",
    )
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token_response.data['access']}")
    return client


def _global_mince() -> FoodItem:
    # The ASDA mince case: OFF carries the grilled column (172/29), the
    # community corrects to the raw label (124/21/4.5).
    return FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="5054070875254",
        barcode="5054070875254",
        name="Lean Beef Steak Mince",
        raw_source_json={},
        kcal_100g="172",
        protein_g_100g="29",
        fat_g_100g="6.3",
        nutriments_json={"energy-kcal_100g": 172, "proteins_100g": 29},
    )


def _proposal(food: FoodItem, email: str, **values: float) -> FoodEditProposal:
    new_values = {
        "kcal_100g": 124.0,
        "protein_g_100g": 21.0,
        "carbs_g_100g": 0.0,
        "fat_g_100g": 4.5,
        "sugars_g_100g": None,
        "fiber_g_100g": None,
        "salt_g_100g": None,
    }
    new_values.update(values)
    return FoodEditProposal.objects.create(
        user=_user(email),
        food_item=food,
        old_values={},
        new_values=new_values,
    )


@pytest.mark.django_db
def test_three_converging_users_promote_median_values() -> None:
    food = _global_mince()
    _proposal(food, "a@example.com", kcal_100g=124.0)
    _proposal(food, "b@example.com", kcal_100g=126.0, protein_g_100g=21.4)
    _proposal(food, "c@example.com", kcal_100g=122.0, protein_g_100g=20.8)

    assert promote_pending_edits(food) is True

    food.refresh_from_db()
    assert food.kcal_100g == Decimal("124")
    assert food.protein_g_100g == Decimal("21")
    assert food.fat_g_100g == Decimal("4.5")
    assert food.community_verified_at is not None
    assert food.content_hash is None
    # The blob mirrors the promoted columns so day totals agree.
    nutriments = food.nutriments_json or {}
    assert nutriments["energy-kcal_100g"] == 124.0
    assert nutriments["proteins_100g"] == 21.0
    assert not FoodEditProposal.objects.filter(
        status=FoodEditProposal.STATUS_PENDING
    ).exists()


@pytest.mark.django_db
def test_below_quorum_or_same_user_never_promotes() -> None:
    food = _global_mince()
    _proposal(food, "a@example.com")
    _proposal(food, "b@example.com")
    assert promote_pending_edits(food) is False

    # A third proposal from an existing editor doesn't add a voice.
    user_a = get_user_model().objects.get(email="a@example.com")
    FoodEditProposal.objects.create(
        user=user_a,
        food_item=food,
        old_values={},
        new_values={"kcal_100g": 124.0, "protein_g_100g": 21.0},
    )
    assert promote_pending_edits(food) is False
    food.refresh_from_db()
    assert food.kcal_100g == Decimal("172")


@pytest.mark.django_db
def test_disputed_values_block_promotion() -> None:
    food = _global_mince()
    _proposal(food, "a@example.com", kcal_100g=124.0)
    _proposal(food, "b@example.com", kcal_100g=125.0)
    # Third user disagrees far beyond tolerance: dispute, no promotion.
    _proposal(food, "c@example.com", kcal_100g=180.0)

    assert promote_pending_edits(food) is False
    food.refresh_from_db()
    assert food.community_verified_at is None


@pytest.mark.django_db
def test_atwater_gate_blocks_inconsistent_cluster() -> None:
    food = _global_mince()
    # Three users agree on values whose macros can't explain the kcal:
    # 4*21 + 9*4.5 = 124.5 expected vs 400 stated.
    for email in ("a@example.com", "b@example.com", "c@example.com"):
        _proposal(food, email, kcal_100g=400.0)

    assert promote_pending_edits(food) is False


@pytest.mark.django_db
@pytest.mark.integration
def test_ingest_cannot_stomp_promoted_nutrition() -> None:
    food = _global_mince()
    for email in ("a@example.com", "b@example.com", "c@example.com"):
        _proposal(food, email)
    assert promote_pending_edits(food) is True

    client = _auth_client("ingester@example.com")
    response = client.post(
        "/api/v1/foods/ingest",
        {
            "source": "openfoodfacts",
            "external_id": "5054070875254",
            "barcode": "5054070875254",
            "name": "Lean Scotch Beef Steak Mince",
            "kcal_100g": "172",
            "protein_g_100g": "29",
            "raw_source_json": {},
            "nutriments_json": {"energy-kcal_100g": 172},
        },
        format="json",
    )

    assert response.status_code == 200
    food.refresh_from_db()
    # Metadata updates, verified nutrition doesn't.
    assert food.name == "Lean Scotch Beef Steak Mince"
    assert food.kcal_100g == Decimal("124")
    assert (food.nutriments_json or {})["energy-kcal_100g"] == 124.0


@pytest.mark.django_db
@pytest.mark.integration
def test_third_override_through_api_triggers_promotion() -> None:
    food = _global_mince()
    for index, email in enumerate(("a@example.com", "b@example.com", "c@example.com")):
        client = _auth_client(email)
        response = client.post(
            "/api/v1/foods/custom",
            {
                "external_id": f"cf-override-{index}",
                "name": "Mince (corrected)",
                "kcal_100g": "124",
                "protein_g_100g": "21",
                "carbs_g_100g": "0",
                "fat_g_100g": "4.5",
                "overrides_food": food.id,
            },
            format="json",
        )
        assert response.status_code == 200

    food.refresh_from_db()
    assert food.community_verified_at is not None
    assert food.kcal_100g == Decimal("124")


@pytest.mark.django_db
def test_sweep_promotes_eligible_foods() -> None:
    food = _global_mince()
    for email in ("a@example.com", "b@example.com", "c@example.com"):
        _proposal(food, email)

    assert sweep() == 1
    assert sweep() == 0  # nothing pending afterwards


@pytest.mark.django_db
def test_serializers_expose_community_verified_at() -> None:
    from django.utils import timezone

    from foods.serializers import FoodItemCompactSerializer, FoodItemSerializer

    food = _global_mince()
    assert FoodItemSerializer(food).data["community_verified_at"] is None
    assert FoodItemCompactSerializer(food).data["community_verified_at"] is None

    food.community_verified_at = timezone.now()
    food.save(update_fields=["community_verified_at"])
    assert FoodItemSerializer(food).data["community_verified_at"] is not None
    assert FoodItemCompactSerializer(food).data["community_verified_at"] is not None
