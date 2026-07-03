import pytest
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient

from foods.models import FoodItem


def _auth_client(email: str = "foodsuser@example.com") -> APIClient:
    user = get_user_model().objects.create_user(
        email=email,
        password="Str0ngPass!word",
        email_verified=True,
    )
    client = APIClient()
    token_response = client.post(
        "/api/v1/auth/token",
        {"email": user.email, "password": "Str0ngPass!word"},
        format="json",
    )
    access_token = token_response.data["access"]
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {access_token}")
    return client


@pytest.mark.django_db
def test_multiple_barcode_less_foods_coexist() -> None:
    user = get_user_model().objects.create_user(
        email="owner@example.com", password="Str0ngPass!word"
    )
    for external_id in ("uuid-1", "uuid-2"):
        FoodItem.objects.create(
            source=FoodItem.SOURCE_CUSTOM,
            external_id=external_id,
            barcode=None,
            name=f"Custom {external_id}",
            raw_source_json={},
            owner=user,
        )

    assert FoodItem.objects.filter(barcode__isnull=True).count() == 2


@pytest.mark.django_db
@pytest.mark.integration
def test_ingest_blank_barcodes_do_not_merge_or_collide() -> None:
    client = _auth_client()

    for external_id, name in (("no-bc-1", "First"), ("no-bc-2", "Second")):
        response = client.post(
            "/api/v1/foods/ingest",
            {
                "source": "openfoodfacts",
                "external_id": external_id,
                "barcode": "",
                "name": name,
                "raw_source_json": {},
            },
            format="json",
        )
        assert response.status_code == 200
        assert response.data["barcode"] is None

    assert FoodItem.objects.count() == 2
    assert set(FoodItem.objects.values_list("name", flat=True)) == {
        "First",
        "Second",
    }


@pytest.mark.django_db
@pytest.mark.integration
def test_ingest_blank_barcode_still_updates_by_external_id() -> None:
    client = _auth_client()

    payload = {
        "source": "openfoodfacts",
        "external_id": "no-bc-1",
        "barcode": "",
        "name": "Original",
        "raw_source_json": {},
    }
    assert (
        client.post("/api/v1/foods/ingest", payload, format="json").status_code == 200
    )

    payload["name"] = "Renamed"
    response = client.post("/api/v1/foods/ingest", payload, format="json")

    assert response.status_code == 200
    assert FoodItem.objects.count() == 1
    assert FoodItem.objects.get(external_id="no-bc-1").name == "Renamed"


@pytest.mark.django_db
def test_deleting_owner_cascades_to_custom_foods() -> None:
    user = get_user_model().objects.create_user(
        email="owner@example.com", password="Str0ngPass!word"
    )
    FoodItem.objects.create(
        source=FoodItem.SOURCE_CUSTOM,
        external_id="uuid-1",
        barcode=None,
        name="Custom",
        raw_source_json={},
        owner=user,
    )
    global_item = FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id="123",
        barcode="123",
        name="Global",
        raw_source_json={},
    )

    user.delete()

    assert list(FoodItem.objects.all()) == [global_item]
