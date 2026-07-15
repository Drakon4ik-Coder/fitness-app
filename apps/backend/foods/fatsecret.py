"""Thin client for the FatSecret Platform API.

Views never touch `requests` directly — all HTTP, token caching, and error
mapping live here so the proxy views stay a couple of lines each.
"""

import logging

import requests
from django.conf import settings
from django.core.cache import cache

logger = logging.getLogger(__name__)

TOKEN_URL = "https://oauth.fatsecret.com/connect/token"
API_URL = "https://platform.fatsecret.com/rest/server.api"
_TOKEN_CACHE_KEY = "fatsecret:oauth-token"

# Connect/read timeouts as a tuple, not a single scalar: a hung partner
# request must never pin a gunicorn worker forever waiting on one socket op.
_TIMEOUT = (5, 15)


class FatSecretNotConfigured(Exception):
    """Raised when FATSECRET_CLIENT_ID/SECRET are blank."""


class FatSecretUpstreamError(Exception):
    """Wraps any FatSecret failure. `status` is the upstream HTTP status when
    known (e.g. 429, 5xx), or None for transport errors / 200-with-error-JSON.
    """

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


def _fetch_token() -> str:
    if not settings.FATSECRET_CLIENT_ID or not settings.FATSECRET_CLIENT_SECRET:
        raise FatSecretNotConfigured

    try:
        response = requests.post(
            TOKEN_URL,
            auth=(settings.FATSECRET_CLIENT_ID, settings.FATSECRET_CLIENT_SECRET),
            data={
                "grant_type": "client_credentials",
                "scope": settings.FATSECRET_SCOPE,
            },
            timeout=_TIMEOUT,
        )
        response.raise_for_status()
        payload = response.json()
        # Inside the try: a 200 with an unexpected body must map to the same
        # 502-shaped upstream error as any other token failure, not a 500.
        token = payload["access_token"]
        expires_in = int(payload["expires_in"])
    except (requests.RequestException, ValueError, KeyError, TypeError) as exc:
        logger.warning("FatSecret token request failed: %s", exc)
        status = getattr(getattr(exc, "response", None), "status_code", None)
        raise FatSecretUpstreamError(
            "FatSecret authentication failed", status=status
        ) from exc

    # Refresh 5 minutes early so an in-flight request never races an
    # expiring token; floor at 60s so a tiny expires_in can't defeat caching.
    cache.set(_TOKEN_CACHE_KEY, token, timeout=max(expires_in - 300, 60))
    return token


def _get_token() -> str:
    token = cache.get(_TOKEN_CACHE_KEY)
    if token is not None:
        return token
    return _fetch_token()


def _call_platform(params: dict[str, str]) -> dict:
    """POST to the platform API with a cached token, handling the 401-retry
    and error-mapping rules shared by every method (search, food.get.v4, ...).
    """

    if settings.FATSECRET_REGION:
        params = {**params, "region": settings.FATSECRET_REGION}

    token = _get_token()
    response = _post_platform(params, token)

    if response.status_code == 401:
        # Tokens can be revoked server-side before expires_in elapses; retry
        # once with a freshly fetched token before giving up.
        cache.delete(_TOKEN_CACHE_KEY)
        token = _fetch_token()
        response = _post_platform(params, token)

    return _parse_platform_response(response)


def _post_platform(params: dict[str, str], token: str) -> requests.Response:
    try:
        return requests.post(
            API_URL,
            headers={"Authorization": f"Bearer {token}"},
            data=params,
            timeout=_TIMEOUT,
        )
    except requests.RequestException as exc:
        logger.warning("FatSecret API request failed: %s", exc)
        status = getattr(getattr(exc, "response", None), "status_code", None)
        raise FatSecretUpstreamError("FatSecret search failed", status=status) from exc


def _parse_platform_response(response: requests.Response) -> dict:
    if response.status_code >= 400:
        logger.warning(
            "FatSecret API returned HTTP %s: %s", response.status_code, response.text
        )
        raise FatSecretUpstreamError(
            "FatSecret search failed", status=response.status_code
        )

    try:
        data = response.json()
    except ValueError as exc:
        logger.warning("FatSecret API returned non-JSON body: %s", exc)
        raise FatSecretUpstreamError("FatSecret search failed") from exc

    if isinstance(data, dict) and "error" in data:
        # FatSecret's app-level errors arrive as HTTP 200. Log the real code
        # and message server-side only — the raised exception stays generic.
        logger.warning("FatSecret application error: %s", data["error"])
        raise FatSecretUpstreamError("FatSecret search failed")

    return data


def search_foods(query: str, page: int = 0, max_results: int = 10) -> dict:
    return _call_platform(
        {
            "method": "foods.search",
            "search_expression": query,
            "page_number": str(page),
            "max_results": str(max_results),
            "format": "json",
        }
    )


def get_food(food_id: str) -> dict:
    return _call_platform(
        {
            "method": "food.get.v4",
            "food_id": food_id,
            "format": "json",
        }
    )
