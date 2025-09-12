from django.test import Client


def test_health():
    c = Client()
    resp = c.get("/health/")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
