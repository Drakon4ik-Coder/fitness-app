"""Edge and failure paths of the foods app (KAN-131 coverage pass)."""

from decimal import Decimal
from io import StringIO
from unittest.mock import MagicMock, patch

import pytest
import requests
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.core.management import call_command
from django.test import override_settings
from rest_framework.test import APIClient

from foods import fatsecret
from foods.images import safe_signature
from foods.models import FoodItem
from foods.serializers import nutrition_snapshot

PASSWORD = "Str0ngPass!word"


@pytest.fixture(autouse=True)
def _clean_cache():
    cache.clear()
    yield
    cache.clear()


def _client(email: str = "foodedge@example.com") -> APIClient:
    get_user_model().objects.create_user(
        email=email, password=PASSWORD, email_verified=True
    )
    client = APIClient()
    token = client.post(
        "/api/v1/auth/token", {"email": email, "password": PASSWORD}, format="json"
    )
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token.data['access']}")
    return client


def _food(external_id: str = "e-1", barcode: str | None = "b-1", **extra) -> FoodItem:
    return FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id=external_id,
        barcode=barcode,
        name=extra.pop("name", "Oats"),
        kcal_100g=Decimal("380"),
        raw_source_json={},
        **extra,
    )


# --- small helpers ------------------------------------------------------------


def test_nutrition_snapshot_reads_plain_dicts_too() -> None:
    snapshot = nutrition_snapshot({"kcal_100g": Decimal("12.5"), "fat_g_100g": None})
    assert snapshot["kcal_100g"] == 12.5
    assert snapshot["fat_g_100g"] is None


def test_safe_signature_defaults_and_strips_unsafe_characters() -> None:
    assert safe_signature(None) == "image"
    assert safe_signature("") == "image"
    assert safe_signature("../../etc") == "....etc"
    assert safe_signature("///") == "image"


@pytest.mark.django_db
def test_promote_food_edits_command_reports_its_sweep() -> None:
    out = StringIO()
    call_command("promote_food_edits", stdout=out)
    assert out.getvalue().strip() == "Promoted 0 food item(s)."


# --- typeahead and check ---------------------------------------------------------


@pytest.mark.django_db
@pytest.mark.integration
def test_typeahead_blank_query_and_bad_limit() -> None:
    client = _client()
    for i in range(12):
        _food(external_id=f"e-{i}", barcode=f"b-{i}", name=f"Oats {i}")

    assert client.get("/api/v1/foods/typeahead", {"q": "  "}).data == []
    # A non-numeric limit falls back to the default page of 10.
    response = client.get("/api/v1/foods/typeahead", {"q": "oats", "limit": "lots"})
    assert response.status_code == 200
    assert len(response.data) == 10


@pytest.mark.django_db
@pytest.mark.integration
def test_check_reports_unknown_foods() -> None:
    client = _client("foodcheck@example.com")
    response = client.post(
        "/api/v1/foods/check",
        {"source": "openfoodfacts", "external_id": "nope", "content_hash": "h"},
        format="json",
    )
    assert response.status_code == 200
    assert response.data == {
        "exists": False,
        "up_to_date": False,
        "food_item_id": None,
        "images_ok": False,
    }


# --- ingest normalization and conflicts --------------------------------------------


@pytest.mark.django_db
@pytest.mark.integration
def test_ingest_drops_blank_signature_and_hash_instead_of_storing_them() -> None:
    client = _client("ingestblank@example.com")
    _food(external_id="x-1", barcode="x-1", content_hash="keep-me")
    response = client.post(
        "/api/v1/foods/ingest",
        {
            "source": "openfoodfacts",
            "external_id": "x-1",
            "barcode": "x-1",
            "name": "Oats",
            "image_signature": "   ",
            "content_hash": "  ",
            "raw_source_json": {},
        },
        format="json",
    )
    assert response.status_code == 200
    item = FoodItem.objects.get(external_id="x-1")
    assert item.content_hash == "keep-me"
    assert item.image_signature is None


@pytest.mark.django_db
@pytest.mark.integration
def test_ingest_rejects_a_barcode_owned_by_another_food() -> None:
    client = _client("ingestclash@example.com")
    _food(external_id="a", barcode="111")
    _food(external_id="b", barcode="222")
    response = client.post(
        "/api/v1/foods/ingest",
        {
            "source": "openfoodfacts",
            "external_id": "b",
            "barcode": "111",
            "name": "Clash",
            "raw_source_json": {},
        },
        format="json",
    )
    assert response.status_code == 400
    assert "barcode" in response.data


# --- FatSecret proxy parameters and upstream failures -------------------------------

FATSECRET = override_settings(
    FATSECRET_CLIENT_ID="id", FATSECRET_CLIENT_SECRET="secret", FATSECRET_AUTH="oauth2"
)


@pytest.mark.django_db
@pytest.mark.integration
def test_fatsecret_search_sanitizes_paging_params() -> None:
    client = _client("fspaging@example.com")
    with patch.object(fatsecret, "search_foods", return_value={"ok": True}) as search:
        response = client.get(
            "/api/v1/foods/fatsecret/search",
            {"q": "burger", "page": "x", "max_results": "y"},
        )
    assert response.status_code == 200
    search.assert_called_once_with("burger", page=0, max_results=10)


def _response(status: int = 200, json_data=None, json_error: Exception | None = None):
    response = MagicMock()
    response.status_code = status
    if json_error is not None:
        response.json.side_effect = json_error
    else:
        response.json.return_value = json_data
    response.raise_for_status.return_value = None
    return response


def test_fatsecret_token_requires_credentials() -> None:
    with override_settings(FATSECRET_CLIENT_ID="", FATSECRET_CLIENT_SECRET=""):
        with pytest.raises(fatsecret.FatSecretNotConfigured):
            fatsecret._fetch_token()


@FATSECRET
def test_fatsecret_malformed_token_body_is_an_upstream_error() -> None:
    with patch("foods.fatsecret.requests.post", return_value=_response(json_data={})):
        with pytest.raises(fatsecret.FatSecretUpstreamError):
            fatsecret._fetch_token()


@FATSECRET
def test_fatsecret_token_transport_failure_is_an_upstream_error() -> None:
    with patch(
        "foods.fatsecret.requests.post",
        side_effect=requests.ConnectionError("down"),
    ):
        with pytest.raises(fatsecret.FatSecretUpstreamError):
            fatsecret._fetch_token()


def test_fatsecret_non_json_body_is_an_upstream_error() -> None:
    with pytest.raises(fatsecret.FatSecretUpstreamError):
        fatsecret._parse_platform_response(_response(json_error=ValueError("html")))


def test_fatsecret_app_error_with_odd_code_still_raises_generically() -> None:
    body = {"error": {"code": "not-a-number", "message": "nope"}}
    with pytest.raises(fatsecret.FatSecretUpstreamError) as raised:
        fatsecret._parse_platform_response(_response(json_data=body))
    assert raised.value.error_code is None
