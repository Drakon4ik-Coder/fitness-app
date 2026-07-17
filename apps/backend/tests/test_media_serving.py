import importlib

import pytest
from django.test import Client, override_settings
from django.urls import clear_url_caches
from django.utils.http import http_date


@pytest.mark.django_db
def test_media_is_served_with_debug_off(tmp_path) -> None:
    # Regression guard for the production 404s: /media/ must be routed even
    # when DEBUG is off, because food serializers hand out backend-hosted
    # media URLs and WhiteNoise only serves staticfiles.
    (tmp_path / "foods").mkdir()
    (tmp_path / "foods" / "front.jpg").write_bytes(b"jpegbytes")

    with override_settings(MEDIA_ROOT=tmp_path, DEBUG=False):
        response = Client().get("/media/foods/front.jpg")

    assert response.status_code == 200
    # serve() returns a streaming FileResponse; the stubs' patched test-client
    # response type doesn't know that.
    streamed = response.streaming_content  # type: ignore[attr-defined]
    assert b"".join(streamed) == b"jpegbytes"


@pytest.mark.django_db
def test_conditional_get_returns_304(tmp_path) -> None:
    # serve() honours If-Modified-Since with an HttpResponseNotModified —
    # this is why _serve_media is annotated HttpResponseBase, not
    # FileResponse (the two sit on different branches of the hierarchy).
    (tmp_path / "foods").mkdir()
    file = tmp_path / "foods" / "front.jpg"
    file.write_bytes(b"jpegbytes")

    with override_settings(MEDIA_ROOT=tmp_path, DEBUG=False):
        response = Client().get(
            "/media/foods/front.jpg",
            HTTP_IF_MODIFIED_SINCE=http_date(file.stat().st_mtime),
        )

    assert response.status_code == 304


@pytest.mark.django_db
def test_missing_media_returns_404(tmp_path) -> None:
    with override_settings(MEDIA_ROOT=tmp_path, DEBUG=False):
        response = Client().get("/media/foods/nope.jpg")

    assert response.status_code == 404


@pytest.mark.django_db
def test_media_route_follows_media_url(tmp_path) -> None:
    # The route regex is derived from MEDIA_URL at URLconf import, so URL
    # generation (ImageField.url) and serving stay aligned if a deployment
    # relocates the media prefix. The URLconf is reloaded under the overridden
    # setting; ROOT_URLCONF in the override makes Django drop its resolver
    # cache on both enter and exit.
    (tmp_path / "foods").mkdir()
    (tmp_path / "foods" / "front.jpg").write_bytes(b"jpegbytes")

    import config.urls as config_urls

    try:
        with override_settings(
            MEDIA_URL="/files/",
            MEDIA_ROOT=tmp_path,
            DEBUG=False,
            ROOT_URLCONF="config.urls",
        ):
            importlib.reload(config_urls)
            client = Client()
            assert client.get("/files/foods/front.jpg").status_code == 200
            assert client.get("/media/foods/front.jpg").status_code == 404
    finally:
        # Rebuild the real /media/ route for the rest of the suite.
        importlib.reload(config_urls)
        clear_url_caches()
