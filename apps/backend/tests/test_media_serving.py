import pytest
from django.test import Client, override_settings


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
def test_missing_media_returns_404(tmp_path) -> None:
    with override_settings(MEDIA_ROOT=tmp_path, DEBUG=False):
        response = Client().get("/media/foods/nope.jpg")

    assert response.status_code == 404
