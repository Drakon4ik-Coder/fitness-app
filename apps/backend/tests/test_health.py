from django.conf import settings
from django.test import Client


def test_health() -> None:
    c = Client()
    resp = c.get("/health/")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok", "version": settings.APP_VERSION}
