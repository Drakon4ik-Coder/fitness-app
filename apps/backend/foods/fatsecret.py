"""Thin client for the FatSecret Platform API.

Views never touch `requests` directly — all HTTP, auth (OAuth 1.0 signing or
OAuth 2.0 token caching, per FATSECRET_AUTH), and error mapping live here so
the proxy views stay a couple of lines each.
"""

import base64
import hashlib
import hmac
import logging
import secrets
import time
from urllib.parse import quote

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


def _oauth1_signed_params(
    params: dict[str, str],
    *,
    nonce: str | None = None,
    timestamp: str | None = None,
) -> dict[str, str]:
    """RFC 5849 two-legged HMAC-SHA1 signing (no token, signing key is
    `secret&`). Every request is individually signed, which is why this mode
    needs no IP whitelisting: FatSecret only enforces the whitelist at the
    OAuth 2.0 token endpoint. nonce/timestamp are injectable for tests only.
    """

    signed = {
        **params,
        "oauth_consumer_key": settings.FATSECRET_CLIENT_ID,
        "oauth_nonce": nonce or secrets.token_hex(16),
        "oauth_signature_method": "HMAC-SHA1",
        "oauth_timestamp": timestamp or str(int(time.time())),
        "oauth_version": "1.0",
    }

    def enc(value: str) -> str:
        # RFC 5849 §3.6 percent-encoding: only ALPHA/DIGIT/-._~ unreserved.
        return quote(str(value), safe="-._~")

    pairs = sorted((enc(k), enc(v)) for k, v in signed.items())
    param_string = "&".join(f"{k}={v}" for k, v in pairs)
    base_string = "&".join(["POST", enc(API_URL), enc(param_string)])
    key = f"{enc(settings.FATSECRET_CLIENT_SECRET)}&"
    digest = hmac.new(key.encode(), base_string.encode(), hashlib.sha1).digest()
    return {**signed, "oauth_signature": base64.b64encode(digest).decode()}


def _call_platform(params: dict[str, str]) -> dict:
    """POST to the platform API, handling the auth mode and the error-mapping
    rules shared by every method (search, food.get.v4, ...).
    """

    if settings.FATSECRET_REGION:
        params = {**params, "region": settings.FATSECRET_REGION}

    if settings.FATSECRET_AUTH == "oauth1":
        if not settings.FATSECRET_CLIENT_ID or not settings.FATSECRET_CLIENT_SECRET:
            raise FatSecretNotConfigured
        response = _post_platform(_oauth1_signed_params(params), token=None)
        return _parse_platform_response(response)

    token = _get_token()
    response = _post_platform(params, token)

    if response.status_code == 401:
        # Tokens can be revoked server-side before expires_in elapses; retry
        # once with a freshly fetched token before giving up. (OAuth 1.0 has
        # no token to refresh — a 401 there falls straight through to the
        # generic upstream-error mapping.)
        cache.delete(_TOKEN_CACHE_KEY)
        token = _fetch_token()
        response = _post_platform(params, token)

    return _parse_platform_response(response)


def _post_platform(params: dict[str, str], token: str | None) -> requests.Response:
    try:
        return requests.post(
            API_URL,
            headers={"Authorization": f"Bearer {token}"} if token else None,
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
