import pytest
from django.test import Client, override_settings
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
