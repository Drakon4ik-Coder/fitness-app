from django.test import Client


def test_privacy_policy_page_renders() -> None:
    c = Client()

    resp = c.get("/privacy")

    assert resp.status_code == 200
    assert resp["Content-Type"].startswith("text/html")
    body = resp.content.decode()
    # The policy must keep covering the Play-required topics — these anchors
    # guard against sections being dropped in a template edit.
    for anchor in [
        "Privacy Policy",
        "Google Sign-In",
        "Health and nutrition data",
        "timezone",
        "barcode",
        "Crash reports",
        "Open Food Facts",
        "Retention",
        "/delete-account",
        "illiadovho@gmail.com",
    ]:
        assert anchor in body, f"privacy policy is missing: {anchor}"


def test_privacy_policy_rejects_post() -> None:
    c = Client()

    resp = c.post("/privacy")

    assert resp.status_code == 405
