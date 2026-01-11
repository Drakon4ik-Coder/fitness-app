import pytest
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient

from foods.models import FoodItem


def _auth_client() -> APIClient:
    user = get_user_model().objects.create_user(
        username="typeaheaduser",
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
    return client


@pytest.mark.django_db
@pytest.mark.integration
def test_foods_typeahead_matches_name_and_brands() -> None:
    client = _auth_client()

    FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="111",
        barcode="111",
        name="Protein Bar",
        brands="Fit Brand",
        raw_source_json={"product": {"product_name": "Protein Bar"}},
    )
    FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="222",
        barcode="222",
        name="Apple",
        brands="Fresh Farms",
        raw_source_json={"product": {"product_name": "Apple"}},
    )

    response = client.get("/api/v1/foods/typeahead?q=protein")

    assert response.status_code == 200
    assert len(response.data) == 1
    assert response.data[0]["name"] == "Protein Bar"
