from unittest.mock import patch

import pytest
from django.contrib.auth import get_user_model
from django.test import override_settings
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
def test_foods_ingest_downloads_and_refreshes_images(tmp_path) -> None:
    client = _auth_client()
    payload = {
        "source": "openfoodfacts",
        "external_id": "123456789",
        "barcode": "123456789",
        "name": "Test Bar",
        "brands": "Test Brand",
        "content_hash": "hash-1",
        "image_signature": "front_en.1",
        "image_large_url": "https://images.openfoodfacts.org/front_en.1.400.jpg",
        "image_small_url": "https://images.openfoodfacts.org/front_en.1.100.jpg",
        "raw_source_json": {"product": {"product_name": "Test Bar"}},
    }

    with override_settings(MEDIA_ROOT=tmp_path):
        with patch("foods.images._fetch_image_bytes", return_value=b"img") as mock_fetch:
            response = client.post("/api/v1/foods/ingest", payload, format="json")

        assert response.status_code == 200
        assert mock_fetch.call_count == 2

        item = FoodItem.objects.get(barcode="123456789")
        assert item.image_status == FoodItem.IMAGE_STATUS_OK
        assert item.image_large.name
        assert item.image_small.name
        first_large_name = item.image_large.name

        update_payload = {
            **payload,
            "content_hash": "hash-2",
            "image_signature": "front_en.2",
            "image_large_url": "https://images.openfoodfacts.org/front_en.2.400.jpg",
            "image_small_url": "https://images.openfoodfacts.org/front_en.2.100.jpg",
        }

        with patch("foods.images._fetch_image_bytes", return_value=b"img2") as mock_fetch_update:
            update_response = client.post(
                "/api/v1/foods/ingest",
                update_payload,
                format="json",
            )

        assert update_response.status_code == 200
        assert mock_fetch_update.call_count == 2

        item.refresh_from_db()
        assert item.image_signature == "front_en.2"
        assert item.image_large.name != first_large_name
