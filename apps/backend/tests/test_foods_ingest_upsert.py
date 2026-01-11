import pytest
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient

from foods.models import FoodItem


def _auth_client() -> APIClient:
    user = get_user_model().objects.create_user(
        username="foodsuser",
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
def test_foods_ingest_upserts_item() -> None:
    client = _auth_client()

    payload = {
        "source": "openfoodfacts",
        "external_id": "123456789",
        "barcode": "123456789",
        "name": "Test Bar",
        "brands": "Test Brand",
        "kcal_100g": "200",
        "protein_g_100g": "10",
        "carbs_g_100g": "20",
        "fat_g_100g": "5",
        "raw_source_json": {"product": {"product_name": "Test Bar"}},
        "nutriments_json": {"energy-kcal_100g": 200},
    }
    response = client.post("/api/v1/foods/ingest", payload, format="json")

    assert response.status_code == 200
    assert response.data["barcode"] == "123456789"
    assert FoodItem.objects.count() == 1

    update_payload = {
        "source": "openfoodfacts",
        "external_id": "123456789",
        "barcode": "123456789",
        "name": "Updated Bar",
        "brands": "Updated Brand",
        "raw_source_json": {"product": {"product_name": "Updated Bar"}},
    }
    update_response = client.post(
        "/api/v1/foods/ingest",
        update_payload,
        format="json",
    )

    assert update_response.status_code == 200
    assert FoodItem.objects.count() == 1
    item = FoodItem.objects.get(barcode="123456789")
    assert item.name == "Updated Bar"
    assert item.brands == "Updated Brand"
