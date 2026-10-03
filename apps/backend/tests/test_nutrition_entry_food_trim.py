import json
from datetime import timedelta
from decimal import Decimal

import pytest
from django.contrib.auth import get_user_model
from django.utils import timezone
from rest_framework.test import APIClient

from foods.models import FoodItem
from foods.serializers import RAW_TRIMMED_MARKER, trim_raw_source
from nutrition.models import MealEntry

# An OFF product shaped like what the mobile client ingests: the fields the
# meal views read back, plus the bulk (nutriments map, image index) they don't.
_OFF_RAW = {
    "product": {
        "code": "3017620422003",
        "product_name": "Hazelnut spread",
        "serving_size": "15 g",
        "categories_tags": ["en:spreads", "en:sweet-spreads"],
        "ecoscore_data": {
            "agribalyse": {
                "agribalyse_food_code": "31032",
                "co2_total": 4.1,
                "name_en": "Chocolate spread with hazelnuts",
            },
            "adjustments": {"packaging": {"value": -9}},
        },
        "nutriments": {f"nutrient-{i}_100g": i for i in range(120)},
        "images": {
            f"front_{lang}": {"sizes": {"400": {"w": 300}}} for lang in "abcdefghij"
        },
    }
}


def _auth_client(email: str = "trim@example.com") -> tuple[APIClient, object]:
    user = get_user_model().objects.create_user(
        email=email, password="Str0ngPass!word", email_verified=True
    )
    client = APIClient()
    token = client.post(
        "/api/v1/auth/token",
        {"email": email, "password": "Str0ngPass!word"},
        format="json",
    )
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token.data['access']}")
    return client, user


def _food() -> FoodItem:
    return FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="3017620422003",
        barcode="3017620422003",
        name="Hazelnut spread",
        kcal_100g=Decimal("539"),
        raw_source_json=_OFF_RAW,
        nutriments_json={"energy-kcal_100g": 539},
    )


def test_trim_keeps_only_what_the_client_reads() -> None:
    trimmed = trim_raw_source(_OFF_RAW)
    assert trimmed == {
        "product": {
            "serving_size": "15 g",
            "categories_tags": ["en:spreads", "en:sweet-spreads"],
            "ecoscore_data": {"agribalyse": {"agribalyse_food_code": "31032"}},
        },
        RAW_TRIMMED_MARKER: True,
    }


def test_trim_handles_fatsecret_and_degenerate_blobs() -> None:
    # FatSecret blobs keep the synthetic serving text, drop the "food" payload.
    fatsecret = {
        "food": {"food_id": "1", "servings": {"serving": []}},
        "serving_size": "1 burger",
    }
    assert trim_raw_source(fatsecret) == {
        "serving_size": "1 burger",
        RAW_TRIMMED_MARKER: True,
    }
    assert trim_raw_source({}) == {RAW_TRIMMED_MARKER: True}
    assert trim_raw_source(None) == {RAW_TRIMMED_MARKER: True}
    assert trim_raw_source({"product": "not-a-dict"}) == {RAW_TRIMMED_MARKER: True}


@pytest.mark.django_db
@pytest.mark.integration
def test_day_and_sync_payloads_carry_the_trimmed_blob() -> None:
    client, user = _auth_client()
    food = _food()
    MealEntry.objects.create(
        user=user,
        food_item=food,
        meal_type=MealEntry.MEAL_LUNCH,
        consumed_at=timezone.now(),
        quantity_g=Decimal("30"),
    )

    day = client.get("/api/v1/nutrition/day")
    assert day.status_code == 200
    entry_food = day.data["meals"]["lunch"][0]["food_item"]
    assert entry_food["raw_source_json"] == trim_raw_source(_OFF_RAW)
    # Nutrition still travels in full via the dedicated field.
    assert entry_food["nutriments_json"] == {"energy-kcal_100g": 539}

    cursor = client.get("/api/v1/nutrition/entries/sync").data["next_cursor"]
    stale = cursor.split("|")[0]
    since = (
        f"{(timezone.datetime.fromisoformat(stale) - timedelta(days=1)).isoformat()}|0"
    )
    page = client.get("/api/v1/nutrition/entries/sync", {"since": since})
    assert page.status_code == 200
    assert page.data["entries"][0]["food_item"]["raw_source_json"] == trim_raw_source(
        _OFF_RAW
    )

    full = len(json.dumps(_OFF_RAW))
    slim = len(json.dumps(entry_food["raw_source_json"]))
    assert slim * 10 < full  # this fixture: well over 90% smaller


@pytest.mark.django_db
@pytest.mark.integration
def test_ingest_never_overwrites_a_full_blob_with_a_trimmed_one() -> None:
    client, _ = _auth_client("trimingest@example.com")
    food = _food()
    response = client.post(
        "/api/v1/foods/ingest",
        {
            "source": "openfoodfacts",
            "external_id": food.external_id,
            "barcode": food.barcode,
            "name": "Hazelnut spread (renamed)",
            "raw_source_json": trim_raw_source(_OFF_RAW),
        },
        format="json",
    )
    assert response.status_code == 200
    food.refresh_from_db()
    assert food.name == "Hazelnut spread (renamed)"  # other fields still update
    assert food.raw_source_json == _OFF_RAW  # the full blob survives


@pytest.mark.django_db
@pytest.mark.integration
def test_food_endpoints_still_return_the_full_blob() -> None:
    client, _ = _auth_client("trimfull@example.com")
    food = _food()
    response = client.post(
        "/api/v1/foods/ingest",
        {
            "source": "openfoodfacts",
            "external_id": food.external_id,
            "barcode": food.barcode,
            "name": food.name,
            "raw_source_json": _OFF_RAW,
        },
        format="json",
    )
    assert response.status_code == 200
    assert response.data["raw_source_json"] == _OFF_RAW
