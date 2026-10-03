"""Shared cache backend (KAN-119).

gunicorn runs several worker processes; Django's default LocMemCache gives
each one a private dict, so DRF throttles, the meal-times cache bust and the
FatSecret token were all per worker. Redis gives every worker one shared
store with atomic counters and native key expiry.
"""

import logging
from typing import Any

from django.core.cache.backends.base import DEFAULT_TIMEOUT
from django.core.cache.backends.redis import RedisCache
from redis.exceptions import ConnectionError as RedisConnectionError
from redis.exceptions import TimeoutError as RedisTimeoutError

logger = logging.getLogger(__name__)

_UNAVAILABLE = (RedisConnectionError, RedisTimeoutError)


class ResilientRedisCache(RedisCache):
    """RedisCache that degrades to cache misses while Redis is unreachable.

    Every DRF-throttled request reads and writes the cache, so with the stock
    backend a Redis outage would turn into a 500 on nearly every endpoint.
    Failing open trades rate-limit enforcement for availability during the
    outage, and a warning is logged so the outage is visible. `incr` keeps the
    stock "missing key" ValueError, so counters built on add()/incr() (the
    account-deletion limiter) see an unavailable Redis as a fresh window that
    can't be stored, and deny.
    """

    def get(self, key: Any, default: Any = None, version: Any = None) -> Any:
        try:
            return super().get(key, default, version)
        except _UNAVAILABLE as exc:
            _warn("get", exc)
            return default

    def set(
        self, key: Any, value: Any, timeout: Any = DEFAULT_TIMEOUT, version: Any = None
    ) -> None:
        try:
            super().set(key, value, timeout, version)
        except _UNAVAILABLE as exc:
            _warn("set", exc)

    def add(
        self, key: Any, value: Any, timeout: Any = DEFAULT_TIMEOUT, version: Any = None
    ) -> bool:
        try:
            return super().add(key, value, timeout, version)
        except _UNAVAILABLE as exc:
            _warn("add", exc)
            return False

    def delete(self, key: Any, version: Any = None) -> bool:
        try:
            return super().delete(key, version)
        except _UNAVAILABLE as exc:
            _warn("delete", exc)
            return False

    def incr(self, key: Any, delta: int = 1, version: Any = None) -> int:
        try:
            return super().incr(key, delta, version)
        except _UNAVAILABLE as exc:
            _warn("incr", exc)
            raise ValueError("Cache unavailable.") from exc


def _warn(operation: str, exc: Exception) -> None:
    logger.warning("Redis cache %s failed, degrading to a miss: %s", operation, exc)
