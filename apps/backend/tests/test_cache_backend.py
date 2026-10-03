import logging
import os
import uuid

import pytest

from config.cache import ResilientRedisCache


@pytest.fixture
def unreachable_cache() -> ResilientRedisCache:
    # Port 1 refuses connections immediately; the short timeouts keep the
    # test fast even where it doesn't.
    return ResilientRedisCache(
        "redis://127.0.0.1:1/0",
        {"OPTIONS": {"socket_connect_timeout": 0.2, "socket_timeout": 0.2}},
    )


def test_unreachable_redis_degrades_to_cache_misses(
    unreachable_cache: ResilientRedisCache, caplog: pytest.LogCaptureFixture
) -> None:
    # KAN-119: a Redis outage must not 500 every throttled request.
    with caplog.at_level(logging.WARNING, logger="config.cache"):
        assert unreachable_cache.get("k", "fallback") == "fallback"
        unreachable_cache.set("k", 1)
        assert unreachable_cache.add("k", 1) is False
        assert unreachable_cache.delete("k") is False
    assert "Redis cache get failed" in caplog.text
    assert "Redis cache set failed" in caplog.text


def test_unreachable_redis_incr_reads_as_missing_key(
    unreachable_cache: ResilientRedisCache,
) -> None:
    # Counters built on add()/incr() (the account-deletion limiter) see the
    # stock "missing key" ValueError and fail closed.
    with pytest.raises(ValueError):
        unreachable_cache.incr("counter")


@pytest.mark.skipif(
    not os.environ.get("REDIS_TEST_URL"),
    reason="needs a real Redis (CI provides one via REDIS_TEST_URL)",
)
def test_workers_share_one_counter_through_redis() -> None:
    # KAN-119's point: two gunicorn workers are two cache instances, and a
    # count one of them records must be visible to the other.
    url = os.environ["REDIS_TEST_URL"]
    worker_a = ResilientRedisCache(url, {"KEY_PREFIX": "kan119-test"})
    worker_b = ResilientRedisCache(url, {"KEY_PREFIX": "kan119-test"})
    key = f"throttle:{uuid.uuid4()}"
    assert worker_a.add(key, 0, timeout=60) is True
    worker_a.incr(key)
    worker_b.incr(key)
    assert worker_a.get(key) == 2
    assert worker_b.get(key) == 2
    worker_a.delete(key)
