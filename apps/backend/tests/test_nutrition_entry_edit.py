from decimal import Decimal

import pytest
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import User
from foods.models import FoodItem
from nutrition.models import MealEntry


def _auth_client(email: str = "edituser@example.com") -> tuple[APIClient, User]:
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


def _food() -> FoodItem:
    return FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="555",
        barcode="555",
        name="Editable Food",
        kcal_100g=Decimal("200"),
        protein_g_100g=Decimal("10"),
        carbs_g_100g=Decimal("20"),
        fat_g_100g=Decimal("5"),
        raw_source_json={"product": {"product_name": "Editable Food"}},
    )


@pytest.mark.django_db
@pytest.mark.integration
def test_patch_entry_updates_quantity_and_recomputes_kcal() -> None:
    client, user = _auth_client()
    entry = MealEntry.objects.create(
        user=user,
        food_item=_food(),
        meal_type=MealEntry.MEAL_BREAKFAST,
        consumed_at=timezone.now(),
        quantity_g=Decimal("100"),
    )

    response = client.patch(
        f"/api/v1/nutrition/entries/{entry.id}",
        {"quantity_g": "250"},
        format="json",
    )

    assert response.status_code == 200
    assert Decimal(str(response.data["quantity_g"])) == Decimal("250.00")
    # 200 kcal/100g * 250g = 500 kcal
    assert response.data["kcal"] == pytest.approx(500.0)
    entry.refresh_from_db()
    assert entry.quantity_g == Decimal("250.00")


@pytest.mark.django_db
@pytest.mark.integration
def test_patch_entry_changes_meal_type() -> None:
    client, user = _auth_client()
    entry = MealEntry.objects.create(
        user=user,
        food_item=_food(),
        meal_type=MealEntry.MEAL_BREAKFAST,
        consumed_at=timezone.now(),
        quantity_g=Decimal("100"),
    )

    response = client.patch(
        f"/api/v1/nutrition/entries/{entry.id}",
        {"meal_type": MealEntry.MEAL_LUNCH},
        format="json",
    )

    assert response.status_code == 200
    assert response.data["meal_type"] == MealEntry.MEAL_LUNCH
    entry.refresh_from_db()
    assert entry.meal_type == MealEntry.MEAL_LUNCH


@pytest.mark.django_db
@pytest.mark.integration
def test_patch_entry_rejects_non_positive_quantity() -> None:
    client, user = _auth_client()
    entry = MealEntry.objects.create(
        user=user,
        food_item=_food(),
        meal_type=MealEntry.MEAL_BREAKFAST,
        consumed_at=timezone.now(),
        quantity_g=Decimal("100"),
    )

    response = client.patch(
        f"/api/v1/nutrition/entries/{entry.id}",
        {"quantity_g": "0"},
        format="json",
    )

    assert response.status_code == 400
    entry.refresh_from_db()
    assert entry.quantity_g == Decimal("100.00")


@pytest.mark.django_db
@pytest.mark.integration
def test_delete_entry_removes_it() -> None:
    client, user = _auth_client()
    entry = MealEntry.objects.create(
        user=user,
        food_item=_food(),
        meal_type=MealEntry.MEAL_BREAKFAST,
        consumed_at=timezone.now(),
        quantity_g=Decimal("100"),
    )

    response = client.delete(f"/api/v1/nutrition/entries/{entry.id}")

    assert response.status_code == 204
    # Soft delete (KAN-28): the row stays as a tombstone so other devices learn
    # about the delete via delta sync, but it's gone from the day log.
    entry.refresh_from_db()
    assert entry.deleted_at is not None
    day = client.get("/api/v1/nutrition/day")
    assert day.status_code == 200
    assert all(len(meals) == 0 for meals in day.json()["meals"].values())


@pytest.mark.django_db
@pytest.mark.integration
def test_cannot_edit_another_users_entry() -> None:
    _, owner = _auth_client(email="owner@example.com")
    entry = MealEntry.objects.create(
        user=owner,
        food_item=_food(),
        meal_type=MealEntry.MEAL_BREAKFAST,
        consumed_at=timezone.now(),
        quantity_g=Decimal("100"),
    )

    attacker_client, _ = _auth_client(email="attacker@example.com")

    patch_response = attacker_client.patch(
        f"/api/v1/nutrition/entries/{entry.id}",
        {"quantity_g": "999"},
        format="json",
    )
    delete_response = attacker_client.delete(f"/api/v1/nutrition/entries/{entry.id}")

    assert patch_response.status_code == 404
    assert delete_response.status_code == 404
    entry.refresh_from_db()
    assert entry.quantity_g == Decimal("100.00")
