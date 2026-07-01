from decimal import Decimal

import pytest
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import User
from foods.models import FoodItem
from nutrients.catalog import NUTRIENT_CATALOG
from nutrients.models import NutrientDefinition
from nutrition.models import MealEntry
from nutrition.utils import calculate_nutrients, nutrient_per_100g


def _auth_client() -> tuple[APIClient, User]:
    user = User.objects.create_user(
        email="nutrientuser@example.com",
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


def _spec(key: str):
    return next(s for s in NUTRIENT_CATALOG if s.key == key)


def test_nutrient_per_100g_converts_units() -> None:
    # Sodium catalog unit is mg; a gram source converts to 1000 mg.
    value = nutrient_per_100g(_spec("sodium"), {"sodium_100g": 1, "sodium_unit": "g"})
    assert value == Decimal("1000")


def test_nutrient_per_100g_defaults_missing_unit_to_grams() -> None:
    value = nutrient_per_100g(_spec("protein"), {"proteins_100g": 12})
    assert value == Decimal("12")


def test_nutrient_per_100g_rejects_unconvertible_unit() -> None:
    value = nutrient_per_100g(
        _spec("vitamin_a"), {"vitamin-a_100g": 500, "vitamin-a_unit": "IU"}
    )
    assert value is None


def test_calculate_nutrients_scales_by_quantity() -> None:
    item = FoodItem(
        nutriments_json={
            "proteins_100g": 10,
            "vitamin-c_100g": 40,
            "vitamin-c_unit": "mg",
        }
    )
    result = calculate_nutrients(item, Decimal("200"))
    assert result["protein"] == Decimal("20")
    assert result["vitamin_c"] == Decimal("80")
    # A nutrient not in the blob is omitted entirely.
    assert "iron" not in result


def test_calculate_nutrients_handles_missing_blob() -> None:
    item = FoodItem(nutriments_json=None)
    assert calculate_nutrients(item, Decimal("100")) == {}


@pytest.mark.django_db
@pytest.mark.integration
def test_day_endpoint_includes_nutrients_and_legacy_totals() -> None:
    client, user = _auth_client()

    item = FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="900",
        barcode="900",
        name="Fortified thing",
        kcal_100g=Decimal("200"),
        protein_g_100g=Decimal("10"),
        carbs_g_100g=Decimal("20"),
        fat_g_100g=Decimal("5"),
        raw_source_json={"product": {}},
        nutriments_json={
            "proteins_100g": 10,
            "vitamin-c_100g": 30,
            "vitamin-c_unit": "mg",
            "sodium_100g": 0.5,
            "sodium_unit": "g",
        },
    )
    now = timezone.now()
    MealEntry.objects.create(
        user=user,
        food_item=item,
        meal_type=MealEntry.MEAL_BREAKFAST,
        consumed_at=now,
        quantity_g=Decimal("200"),
    )

    date_str = timezone.localdate(now).isoformat()
    response = client.get(f"/api/v1/nutrition/day?date={date_str}")

    assert response.status_code == 200
    # Legacy totals still present (back-compat with cache + current UI).
    assert response.data["totals"]["protein_g"] == pytest.approx(20.0)

    nutrients = response.data["nutrients"]
    assert nutrients["vitamin_c"]["amount"] == pytest.approx(60.0)
    assert nutrients["vitamin_c"]["unit"] == "mg"
    assert nutrients["vitamin_c"]["group"] == "vitamins"
    # 200 g * 0.5 g/100g = 1 g sodium -> 1000 mg (catalog unit).
    assert nutrients["sodium"]["amount"] == pytest.approx(1000.0)
    # Nutrients with no source data are absent from the map.
    assert "iron" not in nutrients


@pytest.mark.django_db
@pytest.mark.integration
def test_day_endpoint_empty_nutrients_without_blob() -> None:
    client, user = _auth_client()
    item = FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="901",
        barcode="901",
        name="Bare macros",
        kcal_100g=Decimal("100"),
        raw_source_json={"product": {}},
        nutriments_json=None,
    )
    now = timezone.now()
    MealEntry.objects.create(
        user=user,
        food_item=item,
        meal_type=MealEntry.MEAL_LUNCH,
        consumed_at=now,
        quantity_g=Decimal("100"),
    )
    date_str = timezone.localdate(now).isoformat()
    response = client.get(f"/api/v1/nutrition/day?date={date_str}")
    assert response.status_code == 200
    assert response.data["nutrients"] == {}


@pytest.mark.django_db
@pytest.mark.integration
def test_day_endpoint_reports_partial_nutrient_counts() -> None:
    client, user = _auth_client()

    with_protein = FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="910",
        barcode="910",
        name="Has protein",
        raw_source_json={"product": {}},
        nutriments_json={"proteins_100g": 10},
    )
    without_protein = FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="911",
        barcode="911",
        name="No protein data",
        raw_source_json={"product": {}},
        nutriments_json={"carbohydrates_100g": 20},
    )
    now = timezone.now()
    for item in (with_protein, without_protein):
        MealEntry.objects.create(
            user=user,
            food_item=item,
            meal_type=MealEntry.MEAL_BREAKFAST,
            consumed_at=now,
            quantity_g=Decimal("100"),
        )

    date_str = timezone.localdate(now).isoformat()
    nutrients = client.get(f"/api/v1/nutrition/day?date={date_str}").data["nutrients"]

    # Only one of the two foods reported protein -> a floor total.
    assert nutrients["protein"]["reported"] == 1
    assert nutrients["protein"]["total"] == 2
    # Carbs reported by only the other food; total is still the day's food count.
    assert nutrients["carbs"]["reported"] == 1
    assert nutrients["carbs"]["total"] == 2


@pytest.mark.django_db
def test_nutrient_definitions_seeded() -> None:
    for spec in NUTRIENT_CATALOG:
        defn = NutrientDefinition.objects.get(key=spec.key)
        assert defn.display_name == spec.display_name
        assert defn.unit == spec.unit
        assert defn.is_user_defined is False
