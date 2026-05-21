import io

import pytest
from django.contrib.auth import get_user_model
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import override_settings
from PIL import Image
from rest_framework.test import APIClient

from foods.models import FoodItem


def _make_jpeg(size: tuple[int, int] = (1, 1)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, color=(255, 0, 0)).save(buf, format="JPEG")
    return buf.getvalue()


def _auth_client() -> APIClient:
    user = get_user_model().objects.create_user(
        username="uploaduser",
        password="Str0ngPass!word",
    )
    client = APIClient()
    token_response = client.post(
        "/api/v1/auth/token",
        {"username": user.username, "password": "Str0ngPass!word"},
        format="json",
    )
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token_response.data['access']}")
    return client


def _create_food_item() -> FoodItem:
    return FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="upload-test-001",
        barcode="upload-test-001",
        name="Upload Test Bar",
        brands="Test Brand",
        raw_source_json={"product": {}},
    )


@pytest.mark.django_db
@pytest.mark.integration
def test_upload_valid_image(tmp_path) -> None:
    client = _auth_client()
    item = _create_food_item()
    jpeg = _make_jpeg()

    with override_settings(MEDIA_ROOT=tmp_path):
        response = client.post(
            f"/api/v1/foods/{item.pk}/images",
            {
                "image": SimpleUploadedFile(
                    "image.jpg", jpeg, content_type="image/jpeg"
                ),
                "image_signature": "front_en.1",
            },
            format="multipart",
        )

    assert response.status_code == 200
    assert response.data["images_ok"] is True
    item.refresh_from_db()
    assert item.image_status == FoodItem.IMAGE_STATUS_OK
    assert item.image.name
    assert item.image_signature == "front_en.1"


@pytest.mark.django_db
@pytest.mark.integration
def test_upload_dedup_same_signature(tmp_path) -> None:
    client = _auth_client()
    item = _create_food_item()
    jpeg = _make_jpeg()

    with override_settings(MEDIA_ROOT=tmp_path):
        client.post(
            f"/api/v1/foods/{item.pk}/images",
            {
                "image": SimpleUploadedFile(
                    "image.jpg", jpeg, content_type="image/jpeg"
                ),
                "image_signature": "front_en.1",
            },
            format="multipart",
        )
        item.refresh_from_db()
        first_image_name = item.image.name

        response = client.post(
            f"/api/v1/foods/{item.pk}/images",
            {
                "image": SimpleUploadedFile(
                    "image.jpg", jpeg, content_type="image/jpeg"
                ),
                "image_signature": "front_en.1",
            },
            format="multipart",
        )

    assert response.status_code == 200
    item.refresh_from_db()
    assert item.image.name == first_image_name


@pytest.mark.django_db
@pytest.mark.integration
def test_upload_refreshes_on_new_signature(tmp_path) -> None:
    client = _auth_client()
    item = _create_food_item()
    jpeg = _make_jpeg()

    with override_settings(MEDIA_ROOT=tmp_path):
        client.post(
            f"/api/v1/foods/{item.pk}/images",
            {
                "image": SimpleUploadedFile(
                    "image.jpg", jpeg, content_type="image/jpeg"
                ),
                "image_signature": "front_en.1",
            },
            format="multipart",
        )
        item.refresh_from_db()
        first_image_name = item.image.name

        response = client.post(
            f"/api/v1/foods/{item.pk}/images",
            {
                "image": SimpleUploadedFile(
                    "image.jpg", jpeg, content_type="image/jpeg"
                ),
                "image_signature": "front_en.2",
            },
            format="multipart",
        )

    assert response.status_code == 200
    item.refresh_from_db()
    assert item.image.name != first_image_name
    assert item.image_signature == "front_en.2"


@pytest.mark.django_db
@pytest.mark.integration
def test_upload_oversize_rejected(tmp_path) -> None:
    client = _auth_client()
    item = _create_food_item()
    oversize = b"x" * (5 * 1024 * 1024 + 1)

    with override_settings(MEDIA_ROOT=tmp_path):
        response = client.post(
            f"/api/v1/foods/{item.pk}/images",
            {
                "image": SimpleUploadedFile(
                    "image.jpg", oversize, content_type="image/jpeg"
                ),
            },
            format="multipart",
        )

    assert response.status_code == 400
    assert "size" in response.data["detail"].lower()


@pytest.mark.django_db
@pytest.mark.integration
def test_upload_wrong_content_type_rejected(tmp_path) -> None:
    client = _auth_client()
    item = _create_food_item()

    with override_settings(MEDIA_ROOT=tmp_path):
        response = client.post(
            f"/api/v1/foods/{item.pk}/images",
            {
                "image": SimpleUploadedFile(
                    "image.txt", b"hello", content_type="text/plain"
                ),
            },
            format="multipart",
        )

    assert response.status_code == 400
    assert "content type" in response.data["detail"].lower()


@pytest.mark.django_db
@pytest.mark.integration
def test_upload_invalid_image_bytes_rejected(tmp_path) -> None:
    client = _auth_client()
    item = _create_food_item()

    with override_settings(MEDIA_ROOT=tmp_path):
        response = client.post(
            f"/api/v1/foods/{item.pk}/images",
            {
                "image": SimpleUploadedFile(
                    "fake.jpg", b"not-an-image", content_type="image/jpeg"
                ),
            },
            format="multipart",
        )

    assert response.status_code == 400
    assert "valid image" in response.data["detail"].lower()


@pytest.mark.django_db
@pytest.mark.integration
def test_upload_unauthenticated_rejected(tmp_path) -> None:
    item = _create_food_item()
    client = APIClient()
    jpeg = _make_jpeg()

    with override_settings(MEDIA_ROOT=tmp_path):
        response = client.post(
            f"/api/v1/foods/{item.pk}/images",
            {
                "image": SimpleUploadedFile(
                    "image.jpg", jpeg, content_type="image/jpeg"
                ),
            },
            format="multipart",
        )

    assert response.status_code == 401


@pytest.mark.django_db
@pytest.mark.integration
def test_upload_missing_file_rejected(tmp_path) -> None:
    client = _auth_client()
    item = _create_food_item()

    with override_settings(MEDIA_ROOT=tmp_path):
        response = client.post(
            f"/api/v1/foods/{item.pk}/images",
            {"image_signature": "front_en.1"},
            format="multipart",
        )

    assert response.status_code == 400


@pytest.mark.django_db
@pytest.mark.integration
def test_upload_not_found(tmp_path) -> None:
    client = _auth_client()

    with override_settings(MEDIA_ROOT=tmp_path):
        response = client.post(
            "/api/v1/foods/99999/images",
            {},
            format="multipart",
        )

    assert response.status_code == 404
