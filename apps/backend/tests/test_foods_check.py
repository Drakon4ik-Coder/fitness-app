import pytest
from django.contrib.auth import get_user_model
from django.core.files.base import ContentFile
from django.test import override_settings
from rest_framework.test import APIClient

from foods.models import FoodItem


def _auth_client() -> APIClient:
    user = get_user_model().objects.create_user(
        username="checkuser",
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
def test_foods_check_returns_up_to_date_when_images_ok(tmp_path) -> None:
    client = _auth_client()
    with override_settings(MEDIA_ROOT=tmp_path):
        item = FoodItem.objects.create(
            source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
            external_id="123456789",
            barcode="123456789",
            name="Test Bar",
            brands="Test Brand",
            content_hash="hash-1",
            image_signature="front_en.1",
            image_status=FoodItem.IMAGE_STATUS_OK,
            raw_source_json={"product": {"product_name": "Test Bar"}},
        )
        item.image_large.save(
            "front_en.1_large.jpg",
            ContentFile(b"large"),
            save=False,
        )
        item.image_small.save(
            "front_en.1_small.jpg",
            ContentFile(b"small"),
            save=False,
        )
        item.save()

        response = client.post(
            "/api/v1/foods/check",
            {
                "source": "openfoodfacts",
                "external_id": "123456789",
                "content_hash": "hash-1",
                "image_signature": "front_en.1",
            },
            format="json",
        )

    assert response.status_code == 200
    assert response.data["exists"] is True
    assert response.data["up_to_date"] is True
    assert response.data["images_ok"] is True
    assert response.data["food_item_id"] == item.id


@pytest.mark.django_db
@pytest.mark.integration
def test_foods_check_returns_not_up_to_date_when_images_missing() -> None:
    client = _auth_client()
    item = FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="555",
        barcode="555",
        name="Test Missing",
        brands="Test Brand",
        content_hash="hash-2",
        image_signature="front_en.2",
        raw_source_json={"product": {"product_name": "Test Missing"}},
    )

    response = client.post(
        "/api/v1/foods/check",
        {
            "source": "openfoodfacts",
            "external_id": "555",
            "content_hash": "hash-2",
            "image_signature": "front_en.2",
        },
        format="json",
    )

    assert response.status_code == 200
    assert response.data["exists"] is True
    assert response.data["up_to_date"] is False
    assert response.data["images_ok"] is False
    assert response.data["food_item_id"] == item.id
