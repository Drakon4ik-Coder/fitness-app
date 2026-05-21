import pytest
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient

from foods.models import FoodItem


def _auth_client() -> APIClient:
    user = get_user_model().objects.create_user(
        username="imageuser",
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
def test_foods_ingest_does_not_fetch_images() -> None:
    client = _auth_client()
    payload = {
        "source": "openfoodfacts",
        "external_id": "123456789",
        "barcode": "123456789",
        "name": "Test Bar",
        "brands": "Test Brand",
        "content_hash": "hash-1",
        "image_signature": "front_en.1",
        "image_url": "https://images.openfoodfacts.org/front_en.1.100.jpg",
        "raw_source_json": {"product": {"product_name": "Test Bar"}},
    }

    response = client.post("/api/v1/foods/ingest", payload, format="json")

    assert response.status_code == 200
    item = FoodItem.objects.get(barcode="123456789")
    assert item.image_status == FoodItem.IMAGE_STATUS_NONE
    assert not item.image
    assert response.data["images_ok"] is False


@pytest.mark.django_db
@pytest.mark.integration
def test_foods_ingest_ignores_image_url_fields() -> None:
    client = _auth_client()
    payload = {
        "source": "openfoodfacts",
        "external_id": "111222333",
        "barcode": "111222333",
        "name": "Another Bar",
        "brands": "Brand",
        "image_large_url": "https://images.openfoodfacts.org/large.jpg",
        "image_small_url": "https://images.openfoodfacts.org/small.jpg",
        "raw_source_json": {},
    }

    response = client.post("/api/v1/foods/ingest", payload, format="json")

    assert response.status_code == 200
