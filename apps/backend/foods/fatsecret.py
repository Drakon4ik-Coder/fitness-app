"""Thin client for the FatSecret Platform API.

Views never touch `requests` directly — all HTTP, auth (OAuth 1.0 signing or
OAuth 2.0 token caching, per FATSECRET_AUTH), and error mapping live here so
the proxy views stay a couple of lines each.
"""

import base64
import hashlib
import hmac
import logging
import math
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
_SEARCH_V1_CACHE_KEY = "fatsecret:search-use-v1"
_SEARCH_V1_CACHE_TTL = 60 * 60

# FatSecret documents these as unknown method, missing OAuth 2.0 scope, and
# API not found. They are the only application errors that prove search v3 is
# unavailable; request-limit, temporary-system, timeout, and unknown errors
# must keep their existing upstream-error behavior and never poison this cache.
_V3_UNAVAILABLE_ERROR_CODES = frozenset({10, 14, 23})
_V3_UNAVAILABLE_HTTP_STATUSES = frozenset({403, 404})

# Connect/read timeouts as a tuple, not a single scalar: a hung partner
# request must never pin a gunicorn worker forever waiting on one socket op.
_TIMEOUT = (5, 15)


class FatSecretNotConfigured(Exception):
    """Raised when FATSECRET_CLIENT_ID/SECRET are blank."""


class FatSecretUpstreamError(Exception):
    """Wraps any FatSecret failure. `status` is the upstream HTTP status when
    known (e.g. 429, 5xx), or None for transport errors / 200-with-error-JSON.
    `error_code` is the documented application code from an error JSON body.
    """

    def __init__(
        self,
        message: str,
        status: int | None = None,
        error_code: int | None = None,
    ):
        super().__init__(message)
        self.status = status
        self.error_code = error_code


def _fetch_token() -> str:
    if not settings.FATSECRET_CLIENT_ID or not settings.FATSECRET_CLIENT_SECRET:
        raise FatSecretNotConfigured

    request_started = time.monotonic()
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

    # expires_in counts from when FatSecret minted the response, not from
    # when we cached it — the request round trip has already spent part of
    # the lifetime. Deduct it (ceil, measured from before the request: a
    # strictly conservative bound) so the lifetime cap below can't quietly
    # serve a token past its true expiry.
    remaining = max(expires_in - math.ceil(time.monotonic() - request_started), 0)
    # Refresh 5 minutes early so an in-flight request never races an
    # expiring token; floor at 60s so a modest expires_in can't defeat
    # caching — but never cache past the token's remaining lifetime, or every
    # request in the stale window would burn a guaranteed 401 round trip
    # before the retry path recovers.
    cache.set(_TOKEN_CACHE_KEY, token, timeout=min(max(remaining - 300, 60), remaining))
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
        error = data["error"]
        logger.warning("FatSecret application error: %s", error)
        raw_code = error.get("code") if isinstance(error, dict) else None
        try:
            error_code = None if raw_code is None else int(raw_code)
        except (TypeError, ValueError):
            error_code = None
        raise FatSecretUpstreamError("FatSecret search failed", error_code=error_code)

    return data


def search_foods(query: str, page: int = 0, max_results: int = 10) -> dict:
    shared_params = {
        "search_expression": query,
        "page_number": str(page),
        "max_results": str(max_results),
        "format": "json",
    }
    v1_params = {"method": "foods.search", **shared_params}
    if cache.get(_SEARCH_V1_CACHE_KEY):
        return _call_platform(v1_params)

    try:
        return _call_platform(
            {
                "method": "foods.search.v3",
                "include_food_images": "true",
                **shared_params,
            }
        )
    except FatSecretUpstreamError as exc:
        unavailable = (
            exc.error_code in _V3_UNAVAILABLE_ERROR_CODES
            or exc.status in _V3_UNAVAILABLE_HTTP_STATUSES
        )
        if not unavailable:
            raise

        # Free-tier accounts must pay at most one doomed premier request per
        # hour. The expiring verdict also probes automatically after an
        # upgrade, without a deployment or permanent configuration switch.
        cache.set(_SEARCH_V1_CACHE_KEY, True, timeout=_SEARCH_V1_CACHE_TTL)
        logger.warning(
            "FatSecret foods.search.v3 unavailable (code=%s, status=%s); "
            "downgrading searches to v1 for one hour",
            exc.error_code,
            exc.status,
        )
        return _call_platform(v1_params)


def get_food(food_id: str) -> dict:
    return _call_platform(
        {
            "method": "food.get.v4",
            "food_id": food_id,
            "format": "json",
        }
    )
