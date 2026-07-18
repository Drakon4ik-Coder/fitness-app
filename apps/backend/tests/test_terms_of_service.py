from django.test import Client


def test_terms_of_service_page_renders() -> None:
    c = Client()

    resp = c.get("/terms")

    assert resp.status_code == 200
    assert resp["Content-Type"].startswith("text/html")
    body = resp.content.decode()
    # The terms must keep covering these topics — anchors guard against
    # sections being dropped in a template edit (same pattern as /privacy).
    for anchor in [
        "Terms of Service",
        "not a medical service",
        "Your account",
        "Acceptable use",
        "Your content",
        "Your data and consent",
        "/privacy",
        "Open Food Facts",
        "FatSecret",
        "No warranty",
        "Termination",
        "Governing law",
        "illiadovho@gmail.com",
    ]:
        assert anchor in body, f"terms of service is missing: {anchor}"


def test_terms_of_service_rejects_post() -> None:
    c = Client()

    resp = c.post("/terms")

    assert resp.status_code == 405


def test_privacy_policy_mentions_consent_withdrawal() -> None:
    # KAN-103: the policy must tell users consent can be withdrawn and that
    # account deletion is the withdrawal path.
    body = Client().get("/privacy").content.decode()

    assert "Withdrawing consent" in body
    assert "explicit consent" in body
