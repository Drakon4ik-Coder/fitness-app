from unittest.mock import MagicMock, patch

import pytest
import requests
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from rest_framework.test import APIClient

from foods import fatsecret
from foods.models import FoodItem

POST = "foods.fatsecret.requests.post"
# Most proxy tests pin the OAuth 2.0 token flow they were written against;
# the default mode is oauth1 (signed requests, no token endpoint).
CONFIGURED = override_settings(
    FATSECRET_CLIENT_ID="test-id",
    FATSECRET_CLIENT_SECRET="test-secret",
    FATSECRET_AUTH="oauth2",
)
CONFIGURED_OAUTH1 = override_settings(
    FATSECRET_CLIENT_ID="test-id",
    FATSECRET_CLIENT_SECRET="test-secret",
    FATSECRET_AUTH="oauth1",
)


def _auth_client() -> APIClient:
    user = get_user_model().objects.create_user(
        email="fatsecretuser@example.com",
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


@pytest.fixture(autouse=True)
def _clear_fatsecret_token_cache():
    # Neither the OAuth token nor the tier verdict may leak between tests —
    # both deliberately persist across real requests.
    cache.clear()
    yield
    cache.clear()


def _mock_response(status_code: int = 200, json_data=None, text: str = "") -> MagicMock:
    response = MagicMock()
    response.status_code = status_code
    response.json.return_value = {} if json_data is None else json_data
    response.text = text
    return response


def _token_response(
    access_token: str = "test-token", expires_in: int = 86400
) -> MagicMock:
    return _mock_response(200, {"access_token": access_token, "expires_in": expires_in})


def _post_side_effect(token_responses: list, api_responses: list):
    """Dispatches the shared `requests.post` mock to the token or API queue
    based on the URL, mirroring how fatsecret.py itself calls both endpoints
    through the same function."""

    token_iter = iter(token_responses)
    api_iter = iter(api_responses)

    def _side_effect(url, **kwargs):
        if url == fatsecret.TOKEN_URL:
            return next(token_iter)
        return next(api_iter)

    return _side_effect


@pytest.mark.django_db
@pytest.mark.integration
def test_fatsecret_search_requires_auth() -> None:
    response = APIClient().get("/api/v1/foods/fatsecret/search?q=pizza")
    assert response.status_code == 401


@pytest.mark.django_db
@pytest.mark.integration
def test_fatsecret_food_detail_requires_auth() -> None:
    response = APIClient().get("/api/v1/foods/fatsecret/food/12345")
    assert response.status_code == 401


@pytest.mark.django_db
@pytest.mark.integration
@override_settings(FATSECRET_CLIENT_ID="")
def test_fatsecret_search_returns_503_when_not_configured() -> None:
    client = _auth_client()
    response = client.get("/api/v1/foods/fatsecret/search?q=pizza")
    assert response.status_code == 503


@pytest.mark.django_db
@pytest.mark.integration
@override_settings(FATSECRET_CLIENT_ID="")
def test_fatsecret_food_detail_returns_503_when_not_configured() -> None:
    client = _auth_client()
    response = client.get("/api/v1/foods/fatsecret/food/12345")
    assert response.status_code == 503


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
def test_fatsecret_search_happy_path_passes_through_verbatim() -> None:
    client = _auth_client()
    api_body = {
        "foods_search": {"results": {"food": [{"food_id": "1", "food_name": "Pizza"}]}}
    }
    token_resp = _token_response()
    api_resp = _mock_response(200, api_body)

    with patch(
        POST, side_effect=_post_side_effect([token_resp], [api_resp])
    ) as mock_post:
        response = client.get("/api/v1/foods/fatsecret/search?q=pizza")

    assert response.status_code == 200
    assert response.data == api_body

    assert mock_post.call_count == 2
    token_call, api_call = mock_post.call_args_list
    assert token_call.args[0] == fatsecret.TOKEN_URL
    assert api_call.args[0] == fatsecret.API_URL
    api_params = api_call.kwargs["data"]
    assert api_params["method"] == "foods.search.v3"
    assert api_params["include_food_images"] == "true"
    assert api_params["search_expression"] == "pizza"
    assert api_params["page_number"] == "0"
    assert api_params["max_results"] == "10"
    assert api_params["format"] == "json"
    # Default region is blank: localization is a paid entitlement, so the
    # param must be omitted entirely unless explicitly configured.
    assert "region" not in api_params


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
def test_unavailable_v3_falls_back_to_v1_and_caches_the_verdict(caplog) -> None:
    client = _auth_client()
    token_resp = _token_response()
    unavailable_resp = _mock_response(
        200, {"error": {"code": "14", "message": "Missing scope: premier"}}
    )
    fallback_body = {"foods": {"food": [{"food_id": "1", "food_name": "Pizza"}]}}
    fallback_resp = _mock_response(200, fallback_body)
    cached_fallback_body = {
        "foods": {"food": [{"food_id": "2", "food_name": "Burger"}]}
    }
    cached_fallback_resp = _mock_response(200, cached_fallback_body)

    with (
        patch(
            POST,
            side_effect=_post_side_effect(
                [token_resp],
                [unavailable_resp, fallback_resp, cached_fallback_resp],
            ),
        ) as mock_post,
        patch("foods.fatsecret.cache.set", wraps=cache.set) as mock_cache_set,
    ):
        first = client.get("/api/v1/foods/fatsecret/search?q=pizza")
        second = client.get("/api/v1/foods/fatsecret/search?q=burger")

    assert first.status_code == 200
    assert first.data == fallback_body
    assert second.status_code == 200
    assert second.data == cached_fallback_body
    api_calls = [c for c in mock_post.call_args_list if c.args[0] == fatsecret.API_URL]
    assert [c.kwargs["data"]["method"] for c in api_calls] == [
        "foods.search.v3",
        "foods.search",
        "foods.search",
    ]
    assert api_calls[0].kwargs["data"]["include_food_images"] == "true"
    assert "include_food_images" not in api_calls[1].kwargs["data"]
    verdict_calls = [
        call
        for call in mock_cache_set.call_args_list
        if call.args[0] == fatsecret._SEARCH_V1_CACHE_KEY
    ]
    assert len(verdict_calls) == 1
    assert verdict_calls[0].kwargs["timeout"] == 60 * 60
    downgrade_logs = [
        record
        for record in caplog.records
        if "downgrading searches to v1" in record.getMessage()
    ]
    assert len(downgrade_logs) == 1


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
@pytest.mark.parametrize("unavailable_status", [403, 404])
def test_unavailable_v3_http_status_falls_back_to_v1(
    unavailable_status: int,
) -> None:
    client = _auth_client()
    token_resp = _token_response()
    unavailable_resp = _mock_response(unavailable_status, text="not entitled")
    fallback_body = {"foods": {"food": {"food_id": "1", "food_name": "Solo"}}}
    fallback_resp = _mock_response(200, fallback_body)

    with patch(
        POST,
        side_effect=_post_side_effect([token_resp], [unavailable_resp, fallback_resp]),
    ) as mock_post:
        response = client.get("/api/v1/foods/fatsecret/search?q=pizza")

    assert response.status_code == 200
    assert response.data == fallback_body
    api_calls = [c for c in mock_post.call_args_list if c.args[0] == fatsecret.API_URL]
    assert [c.kwargs["data"]["method"] for c in api_calls] == [
        "foods.search.v3",
        "foods.search",
    ]


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
@override_settings(FATSECRET_REGION="GB")
def test_explicit_fatsecret_region_is_forwarded() -> None:
    client = _auth_client()
    token_resp = _token_response()
    api_resp = _mock_response(200, {"foods": {"food": []}})

    with patch(
        POST, side_effect=_post_side_effect([token_resp], [api_resp])
    ) as mock_post:
        response = client.get("/api/v1/foods/fatsecret/search?q=pizza")

    assert response.status_code == 200
    api_call = [c for c in mock_post.call_args_list if c.args[0] == fatsecret.API_URL]
    assert api_call[0].kwargs["data"]["region"] == "GB"


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
def test_fatsecret_token_is_cached_across_requests() -> None:
    client = _auth_client()
    token_resp = _token_response()
    api_resp_1 = _mock_response(200, {"foods": {"food": []}})
    api_resp_2 = _mock_response(200, {"foods": {"food": []}})

    with patch(
        POST, side_effect=_post_side_effect([token_resp], [api_resp_1, api_resp_2])
    ) as mock_post:
        first = client.get("/api/v1/foods/fatsecret/search?q=pizza")
        second = client.get("/api/v1/foods/fatsecret/search?q=burger")

    assert first.status_code == 200
    assert second.status_code == 200
    token_calls = [
        c for c in mock_post.call_args_list if c.args[0] == fatsecret.TOKEN_URL
    ]
    assert len(token_calls) == 1


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
def test_fatsecret_retries_once_after_platform_401() -> None:
    client = _auth_client()
    token_resp_1 = _token_response(access_token="token-1")
    token_resp_2 = _token_response(access_token="token-2")
    unauthorized_resp = _mock_response(401)
    success_resp = _mock_response(200, {"foods": {"food": []}})

    with patch(
        POST,
        side_effect=_post_side_effect(
            [token_resp_1, token_resp_2], [unauthorized_resp, success_resp]
        ),
    ) as mock_post:
        response = client.get("/api/v1/foods/fatsecret/search?q=pizza")

    assert response.status_code == 200
    token_calls = [
        c for c in mock_post.call_args_list if c.args[0] == fatsecret.TOKEN_URL
    ]
    api_calls = [c for c in mock_post.call_args_list if c.args[0] == fatsecret.API_URL]
    assert len(token_calls) == 2  # invalidated + refetched once
    assert len(api_calls) == 2  # original 401 + retry


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
def test_fatsecret_application_level_error_returns_502() -> None:
    client = _auth_client()
    token_resp = _token_response()
    error_resp = _mock_response(200, {"error": {"code": 5, "message": "boom"}})

    with patch(
        POST, side_effect=_post_side_effect([token_resp], [error_resp])
    ) as mock_post:
        response = client.get("/api/v1/foods/fatsecret/search?q=pizza")

    assert response.status_code == 502
    assert response.data["detail"] == "Food search partner error."
    api_calls = [c for c in mock_post.call_args_list if c.args[0] == fatsecret.API_URL]
    assert [c.kwargs["data"]["method"] for c in api_calls] == ["foods.search.v3"]
    assert cache.get(fatsecret._SEARCH_V1_CACHE_KEY) is None


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
@pytest.mark.parametrize("error_code", [20, 24])
def test_fatsecret_transient_application_error_does_not_downgrade(
    error_code: int,
) -> None:
    client = _auth_client()
    token_resp = _token_response()
    error_resp = _mock_response(
        200, {"error": {"code": error_code, "message": "temporary failure"}}
    )

    with patch(
        POST, side_effect=_post_side_effect([token_resp], [error_resp])
    ) as mock_post:
        response = client.get("/api/v1/foods/fatsecret/search?q=pizza")

    assert response.status_code == 502
    api_calls = [c for c in mock_post.call_args_list if c.args[0] == fatsecret.API_URL]
    assert [c.kwargs["data"]["method"] for c in api_calls] == ["foods.search.v3"]
    assert cache.get(fatsecret._SEARCH_V1_CACHE_KEY) is None


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
def test_fatsecret_upstream_rate_limit_returns_429_with_generic_detail() -> None:
    client = _auth_client()
    token_resp = _token_response()
    rate_limited_resp = _mock_response(429, text="Too Many Requests - quota exceeded")

    with patch(
        POST, side_effect=_post_side_effect([token_resp], [rate_limited_resp])
    ) as mock_post:
        response = client.get("/api/v1/foods/fatsecret/search?q=pizza")

    assert response.status_code == 429
    assert response.data["detail"] == "Food search partner is rate limited."
    api_calls = [c for c in mock_post.call_args_list if c.args[0] == fatsecret.API_URL]
    assert [c.kwargs["data"]["method"] for c in api_calls] == ["foods.search.v3"]
    assert cache.get(fatsecret._SEARCH_V1_CACHE_KEY) is None


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
@pytest.mark.parametrize("upstream_status", [500, 503])
def test_fatsecret_server_error_does_not_downgrade(upstream_status: int) -> None:
    client = _auth_client()
    token_resp = _token_response()
    server_error_resp = _mock_response(upstream_status, text="temporary failure")

    with patch(
        POST, side_effect=_post_side_effect([token_resp], [server_error_resp])
    ) as mock_post:
        response = client.get("/api/v1/foods/fatsecret/search?q=pizza")

    assert response.status_code == 502
    api_calls = [c for c in mock_post.call_args_list if c.args[0] == fatsecret.API_URL]
    assert [c.kwargs["data"]["method"] for c in api_calls] == ["foods.search.v3"]
    assert cache.get(fatsecret._SEARCH_V1_CACHE_KEY) is None


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
def test_fatsecret_connection_error_returns_502() -> None:
    client = _auth_client()
    token_resp = _token_response()

    def _side_effect(url, **kwargs):
        if url == fatsecret.TOKEN_URL:
            return token_resp
        raise requests.exceptions.ConnectionError("connection refused")

    with patch(POST, side_effect=_side_effect):
        response = client.get("/api/v1/foods/fatsecret/search?q=pizza")

    assert response.status_code == 502


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
def test_fatsecret_timeout_does_not_downgrade() -> None:
    client = _auth_client()
    token_resp = _token_response()

    def _side_effect(url, **kwargs):
        if url == fatsecret.TOKEN_URL:
            return token_resp
        raise requests.exceptions.Timeout("read timed out")

    with patch(POST, side_effect=_side_effect) as mock_post:
        response = client.get("/api/v1/foods/fatsecret/search?q=pizza")

    assert response.status_code == 502
    api_calls = [c for c in mock_post.call_args_list if c.args[0] == fatsecret.API_URL]
    assert len(api_calls) == 1
    assert api_calls[0].kwargs["data"]["method"] == "foods.search.v3"
    assert cache.get(fatsecret._SEARCH_V1_CACHE_KEY) is None


@pytest.mark.django_db
@pytest.mark.integration
def test_fatsecret_search_blank_query_returns_400() -> None:
    client = _auth_client()
    response = client.get("/api/v1/foods/fatsecret/search?q=")
    assert response.status_code == 400


@pytest.mark.django_db
@pytest.mark.integration
@pytest.mark.parametrize(
    "food_id",
    [
        "abc",
        "²",  # superscript: isdigit() True, but not an ASCII digit
        "١٢٣",  # Arabic-Indic: even isdecimal() True — must still be rejected
        "12³4",
    ],
)
def test_fatsecret_food_detail_non_ascii_numeric_id_returns_400(
    food_id: str,
) -> None:
    client = _auth_client()
    response = client.get(f"/api/v1/foods/fatsecret/food/{food_id}")
    assert response.status_code == 400


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
def test_fatsecret_food_detail_happy_path_passes_through_verbatim() -> None:
    client = _auth_client()
    api_body = {"food": {"food_id": "12345", "food_name": "Widget"}}
    token_resp = _token_response()
    api_resp = _mock_response(200, api_body)

    with patch(
        POST, side_effect=_post_side_effect([token_resp], [api_resp])
    ) as mock_post:
        response = client.get("/api/v1/foods/fatsecret/food/12345")

    assert response.status_code == 200
    assert response.data == api_body

    api_calls = [c for c in mock_post.call_args_list if c.args[0] == fatsecret.API_URL]
    assert len(api_calls) == 1
    api_params = api_calls[0].kwargs["data"]
    assert api_params["method"] == "food.get.v4"
    assert api_params["food_id"] == "12345"


@pytest.mark.integration
def test_mistyped_fatsecret_auth_fails_at_settings_import(monkeypatch) -> None:
    # The client treats every value except "oauth1" as the token flow, so a
    # typo must die loudly at startup instead of silently selecting OAuth 2.0
    # (which 502s behind non-whitelisted egress). Validation lives in the
    # settings module because that import is the only check gunicorn runs.
    import importlib

    from django.core.exceptions import ImproperlyConfigured

    from config.settings import base as base_settings

    monkeypatch.setenv("FATSECRET_AUTH", "oauth-1")
    try:
        with pytest.raises(ImproperlyConfigured, match="FATSECRET_AUTH"):
            importlib.reload(base_settings)
    finally:
        # Restore the module's globals before other tests import from it.
        monkeypatch.delenv("FATSECRET_AUTH", raising=False)
        importlib.reload(base_settings)


@pytest.mark.integration
@CONFIGURED
@pytest.mark.parametrize(
    ("expires_in", "expected_ttl"),
    [
        # All cases assume the mocked 2s token-request round trip below:
        # expires_in counts from response minting, so 2s of lifetime is
        # already gone by the time the token is cached.
        (86400, 86098),  # normal: 5-min early-refresh margin
        (200, 60),  # short: margin would go negative, floor keeps caching
        (30, 28),  # tiny: TTL capped at the post-round-trip lifetime
        (2, 0),  # degenerate: lifetime consumed in transit -> never cached
    ],
)
def test_token_cache_ttl_never_outlives_the_token(
    expires_in: int, expected_ttl: int
) -> None:
    token_resp = _token_response(expires_in=expires_in)
    with (
        patch(POST, return_value=token_resp),
        # _fetch_token samples monotonic() before the request and after the
        # response: pin a 2s round trip so the TTL is deterministic.
        patch("foods.fatsecret.time.monotonic", side_effect=[100.0, 102.0]),
        patch("foods.fatsecret.cache.set") as mock_set,
    ):
        fatsecret._fetch_token()

    assert mock_set.call_args.kwargs["timeout"] == expected_ttl


@pytest.mark.integration
@CONFIGURED_OAUTH1
def test_oauth1_signature_matches_reference_vector() -> None:
    # Expected value computed with an independent RFC 5849 implementation that
    # itself reproduces the OAuth Core 1.0 Appendix A.5 known-answer vector
    # (tR3+Ty81lMeYAr/Fid0kMTYa/WM=). Guards the percent-encoding, parameter
    # sorting, base-string, and signing-key ("secret&", no token) rules.
    signed = fatsecret._oauth1_signed_params(
        {
            "method": "foods.search",
            "search_expression": "pizza",
            "page_number": "0",
            "max_results": "10",
            "format": "json",
        },
        nonce="fixed-nonce",
        timestamp="1752537600",
    )
    assert signed["oauth_signature"] == "uDvRdIYqn1yFRDKrkVXPok5zTzo="
    assert signed["oauth_consumer_key"] == "test-id"
    assert signed["oauth_signature_method"] == "HMAC-SHA1"


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED_OAUTH1
def test_fatsecret_oauth1_mode_signs_request_and_skips_token_endpoint() -> None:
    client = _auth_client()
    api_body = {"foods": {"food": [{"food_id": "1", "food_name": "Pizza"}]}}
    api_resp = _mock_response(200, api_body)

    with patch(POST, return_value=api_resp) as mock_post:
        response = client.get("/api/v1/foods/fatsecret/search?q=pizza")

    assert response.status_code == 200
    assert response.data == api_body

    # Exactly one HTTP call: the signed platform request. No token fetch, no
    # Bearer header — the signature in the form body is the whole auth story.
    assert mock_post.call_count == 1
    call = mock_post.call_args
    assert call.args[0] == fatsecret.API_URL
    assert call.kwargs["headers"] is None
    api_params = call.kwargs["data"]
    assert api_params["method"] == "foods.search.v3"
    assert api_params["include_food_images"] == "true"
    assert api_params["search_expression"] == "pizza"
    assert api_params["oauth_consumer_key"] == "test-id"
    assert api_params["oauth_signature_method"] == "HMAC-SHA1"
    assert api_params["oauth_signature"]


@pytest.mark.django_db
@pytest.mark.integration
@override_settings(FATSECRET_CLIENT_ID="", FATSECRET_AUTH="oauth1")
def test_fatsecret_oauth1_mode_unconfigured_returns_503() -> None:
    client = _auth_client()
    response = client.get("/api/v1/foods/fatsecret/search?q=pizza")
    assert response.status_code == 503


@pytest.mark.django_db
@pytest.mark.integration
@CONFIGURED
def test_fatsecret_proxy_is_rate_limited_across_both_endpoints(monkeypatch) -> None:
    # Every proxied call spends the app-wide FatSecret quota, so the shared
    # "fatsecret" scope must cap a single account well below the default user
    # rate — search and detail draw from one bucket. DRF binds the rate table
    # as a class attribute at import, so patch it there (same as the accounts
    # throttle tests). The client is built first: login's own ScopedRateThrottle
    # would raise ImproperlyConfigured on a rate table without its scope.
    from rest_framework.throttling import ScopedRateThrottle

    client = _auth_client()
    monkeypatch.setattr(ScopedRateThrottle, "THROTTLE_RATES", {"fatsecret": "2/min"})

    token_resp = _token_response()
    search_resp = _mock_response(200, {"foods": {"food": []}})
    detail_resp = _mock_response(200, {"food": {"food_id": "1"}})

    # Only two upstream responses are queued: if the third request were not
    # throttled before reaching the handler, the mock would raise StopIteration.
    with patch(
        POST, side_effect=_post_side_effect([token_resp], [search_resp, detail_resp])
    ):
        assert client.get("/api/v1/foods/fatsecret/search?q=pizza").status_code == 200
        assert client.get("/api/v1/foods/fatsecret/food/1").status_code == 200
        throttled = client.get("/api/v1/foods/fatsecret/search?q=pizza")

    assert throttled.status_code == 429


@pytest.mark.django_db
@pytest.mark.integration
def test_foods_ingest_accepts_fatsecret_source() -> None:
    client = _auth_client()
    payload = {
        "source": "fatsecret",
        "external_id": "987654321",
        "barcode": "987654321",
        "name": "Test FatSecret Item",
        "brands": "Test Brand",
        "kcal_100g": "150",
        "protein_g_100g": "8",
        "carbs_g_100g": "15",
        "fat_g_100g": "4",
        "raw_source_json": {"food": {"food_name": "Test FatSecret Item"}},
    }
    response = client.post("/api/v1/foods/ingest", payload, format="json")

    assert response.status_code == 200
    item = FoodItem.objects.get(barcode="987654321")
    assert item.source == "fatsecret"
