from decimal import Decimal

import pytest
from django.contrib.auth.models import User
from django.utils import timezone
from rest_framework.test import APIClient

from foods.models import FoodItem
from nutrition.models import MealEntry


def _auth_client() -> tuple[APIClient, User]:
    user = User.objects.create_user(
        username="mealuser",
        password="Str0ngPass!word",
    )
    client = APIClient()
    token_response = client.post(
        "/api/v1/auth/token",
        {"username": user.username, "password": "Str0ngPass!word"},
        format="json",
    )
    access_token = token_response.data["access"]
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {access_token}")
    return client, user


@pytest.mark.django_db
@pytest.mark.integration
def test_nutrition_day_totals_and_grouping() -> None:
    client, user = _auth_client()

    item_a = FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="333",
        barcode="333",
        name="Test A",
        kcal_100g=Decimal("200"),
        protein_g_100g=Decimal("10"),
        carbs_g_100g=Decimal("20"),
        fat_g_100g=Decimal("5"),
        raw_source_json={"product": {"product_name": "Test A"}},
    )
    item_b = FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="444",
        barcode="444",
        name="Test B",
        kcal_100g=Decimal("100"),
        protein_g_100g=Decimal("2"),
        carbs_g_100g=Decimal("10"),
        fat_g_100g=Decimal("1"),
        raw_source_json={"product": {"product_name": "Test B"}},
    )

    now = timezone.now()
    MealEntry.objects.create(
        user=user,
        food_item=item_a,
        meal_type=MealEntry.MEAL_BREAKFAST,
        consumed_at=now,
        quantity_g=Decimal("50"),
    )
    MealEntry.objects.create(
        user=user,
        food_item=item_b,
        meal_type=MealEntry.MEAL_LUNCH,
        consumed_at=now,
        quantity_g=Decimal("100"),
    )

    date_str = timezone.localdate().isoformat()
    response = client.get(f"/api/v1/nutrition/day?date={date_str}")

    assert response.status_code == 200
    totals = response.data["totals"]
    assert totals["kcal"] == pytest.approx(200.0)
    assert totals["protein_g"] == pytest.approx(7.0)
    assert totals["carbs_g"] == pytest.approx(20.0)
    assert totals["fat_g"] == pytest.approx(3.5)
    assert len(response.data["meals"]["breakfast"]) == 1
    assert len(response.data["meals"]["lunch"]) == 1
