import pytest
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient

from external_catalog.models import ExternalFoodItemCache


def _auth_client() -> APIClient:
    user = get_user_model().objects.create_user(
        username="cataloguser",
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
def test_barcode_lookup_returns_fetch_external_payload() -> None:
    client = _auth_client()

    response = client.get("/api/v1/foods/barcode/0000000000000")

    assert response.status_code == 404
    assert response.data["fetch_external"] is True
    assert response.data["source"] == ExternalFoodItemCache.SOURCE_OPEN_FOOD_FACTS


@pytest.mark.django_db
@pytest.mark.integration
def test_off_ingest_requires_auth() -> None:
    client = APIClient()

    response = client.post(
        "/api/v1/external/off/ingest",
        {"barcode": "123", "raw_json": {"product": {}}},
        format="json",
    )

    assert response.status_code == 401


@pytest.mark.django_db
@pytest.mark.integration
def test_off_ingest_upserts_cache() -> None:
    client = _auth_client()

    payload = {
        "barcode": "123",
        "raw_json": {
            "product": {
                "product_name": "Test Bar",
                "brands": "Test Brand",
                "nutriments": {"energy-kcal_100g": 200},
            }
        },
    }
    response = client.post("/api/v1/external/off/ingest", payload, format="json")

    assert response.status_code == 200
    assert response.data["barcode"] == "123"
    assert response.data["nutriments_json"] == {"energy-kcal_100g": 200}
    assert ExternalFoodItemCache.objects.count() == 1

    update_payload = {
        "barcode": "123",
        "raw_json": {
            "product": {
                "product_name": "Updated Bar",
                "brands": "Updated Brand",
            }
        },
    }
    update_response = client.post(
        "/api/v1/external/off/ingest",
        update_payload,
        format="json",
    )

    assert update_response.status_code == 200
    assert ExternalFoodItemCache.objects.count() == 1
    item = ExternalFoodItemCache.objects.get(barcode="123")
    assert item.normalized_name == "Updated Bar"
    assert item.brands == "Updated Brand"
