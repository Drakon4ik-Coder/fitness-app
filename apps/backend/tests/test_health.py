from django.conf import settings
from django.test import Client, override_settings


def test_health() -> None:
    c = Client()
    resp = c.get("/health/")
    assert resp.status_code == 200
    assert resp.json() == {
        "status": "ok",
        "version": settings.APP_VERSION,
        "min_supported_build": settings.MIN_SUPPORTED_APP_BUILD,
    }


@override_settings(MIN_SUPPORTED_APP_BUILD=417)
def test_health_min_supported_build_follows_setting() -> None:
    # The value is env-driven (MIN_SUPPORTED_APP_BUILD) so ops can raise it
    # without a code deploy; that only works if the view reads the setting per
    # request instead of capturing it at import — which is what this asserts.
    resp = Client().get("/health/")
    assert resp.json()["min_supported_build"] == 417
