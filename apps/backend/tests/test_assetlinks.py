from django.test import Client


def test_assetlinks_returns_statement_when_fingerprints_configured(settings) -> None:
    settings.ANDROID_APP_PACKAGE = "uk.drakon4ik.symbio"
    settings.ANDROID_CERT_FINGERPRINTS = ["AA:BB:CC", "DD:EE:FF"]
    c = Client()

    resp = c.get("/.well-known/assetlinks.json")

    assert resp.status_code == 200
    assert resp["Content-Type"] == "application/json"
    body = resp.json()
    assert isinstance(body, list) and len(body) == 1
    statement = body[0]
    assert statement["relation"] == ["delegate_permission/common.get_login_creds"]
    target = statement["target"]
    assert target["namespace"] == "android_app"
    assert target["package_name"] == "uk.drakon4ik.symbio"
    assert target["sha256_cert_fingerprints"] == ["AA:BB:CC", "DD:EE:FF"]


def test_assetlinks_is_empty_list_when_no_fingerprints(settings) -> None:
    settings.ANDROID_CERT_FINGERPRINTS = []
    c = Client()

    resp = c.get("/.well-known/assetlinks.json")

    assert resp.status_code == 200
    assert resp.json() == []
