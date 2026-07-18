"""Signed policy consent (KAN-103): registration checkboxes, the versioned
acceptance record, and the API gate for unconsented users.

The test settings run with POLICY_VERSION = "" (gate off, like the throttles),
so every test that exercises the gate sets a real version via the ``settings``
fixture first.
"""

from unittest.mock import patch

import pytest
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient

from accounts.models import PolicyAcceptance
from accounts.services import create_user_with_defaults, record_policy_acceptance

REGISTER = "/api/v1/auth/register"
ACCEPT = "/api/v1/auth/accept-policy"
GATED = "/api/v1/preferences/"  # any consent-gated endpoint works
CONSENTS = {"accept_terms": True, "accept_health_data": True}


def _register_payload(**overrides):
    data = {"email": "consent@example.com", "password": "Str0ngPass!word", **CONSENTS}
    data.update(overrides)
    return data


def _consented_client(settings, *, accepted: bool = True) -> APIClient:
    settings.POLICY_VERSION = "2026-07-18"
    user = get_user_model().objects.create_user(
        email="user@example.com", password="Str0ngPass!word", email_verified=True
    )
    if accepted:
        record_policy_acceptance(user)
    client = APIClient()
    client.force_authenticate(user)
    return client


# ---------------------------------------------------------------------------
# Registration checkboxes
# ---------------------------------------------------------------------------


@pytest.mark.django_db
@pytest.mark.integration
def test_register_without_consent_flags_creates_unconsented_user(settings) -> None:
    # Released builds predate the checkboxes and send neither flag; requiring
    # them would break their signups (the contract-compat CI gate refuses
    # that). Such accounts start unconsented and the API gate holds them at
    # the consent screen — same as Google sign-ins.
    settings.POLICY_VERSION = "2026-07-18"

    response = APIClient().post(
        REGISTER,
        {"email": "consent@example.com", "password": "Str0ngPass!word"},
        format="json",
    )

    assert response.status_code == 201
    user = get_user_model().objects.get(email="consent@example.com")
    assert user.accepted_policy_version == ""
    assert not PolicyAcceptance.objects.filter(user=user).exists()


@pytest.mark.django_db
@pytest.mark.integration
@pytest.mark.parametrize("flag", ["accept_terms", "accept_health_data"])
def test_register_rejects_unticked_consent(flag: str) -> None:
    # False is a field error, not a silent default — no pre-ticked boxes and
    # no consent by omission (GDPR Recital 32).
    response = APIClient().post(
        REGISTER, _register_payload(**{flag: False}), format="json"
    )

    assert response.status_code == 400
    assert flag in response.data
    assert not get_user_model().objects.filter(email="consent@example.com").exists()


@pytest.mark.django_db
@pytest.mark.integration
def test_register_records_versioned_acceptance(settings) -> None:
    settings.POLICY_VERSION = "2026-07-18"

    response = APIClient().post(REGISTER, _register_payload(), format="json")

    assert response.status_code == 201
    user = get_user_model().objects.get(email="consent@example.com")
    assert user.accepted_policy_version == "2026-07-18"
    acceptance = PolicyAcceptance.objects.get(user=user)
    assert acceptance.policy_version == "2026-07-18"
    # Both consents are recorded with their own timestamp (Art. 9 keeps the
    # health-data consent distinguishable in the record).
    assert acceptance.accepted_at is not None
    assert acceptance.health_consent_at is not None


# ---------------------------------------------------------------------------
# The API gate
# ---------------------------------------------------------------------------


@pytest.mark.django_db
@pytest.mark.integration
def test_gated_endpoint_rejects_unconsented_user_with_code(settings) -> None:
    client = _consented_client(settings, accepted=False)

    response = client.get(GATED)

    assert response.status_code == 403
    # Machine-readable code — the app distinguishes "must consent" from
    # ordinary permission failures by it.
    assert response.data["code"] == "policy_consent_required"


@pytest.mark.django_db
@pytest.mark.integration
def test_gated_endpoint_allows_consented_user(settings) -> None:
    client = _consented_client(settings)

    assert client.get(GATED).status_code == 200


@pytest.mark.django_db
@pytest.mark.integration
def test_google_login_user_starts_unconsented_and_gated(settings) -> None:
    # Google sign-in creates the account without checkboxes; the user must be
    # gated until the in-app consent screen posts accept-policy.
    settings.POLICY_VERSION = "2026-07-18"
    claims = {
        "aud": "test-client-id",
        "email": "googler@example.com",
        "email_verified": True,
        "name": "Goog Ler",
    }
    with patch(
        "accounts.views.google_id_token.verify_oauth2_token", return_value=claims
    ):
        login = APIClient().post(
            "/api/v1/auth/google", {"id_token": "x"}, format="json"
        )
    assert login.status_code == 200

    client = APIClient()
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {login.data['access']}")

    gated = client.get(GATED)
    assert gated.status_code == 403
    assert gated.data["code"] == "policy_consent_required"

    # /auth/me stays open so the app can read the policy state that drives
    # the consent screen.
    me = client.get("/api/v1/auth/me")
    assert me.status_code == 200
    assert me.data["accepted_policy_version"] == ""
    assert me.data["current_policy_version"] == "2026-07-18"


@pytest.mark.django_db
@pytest.mark.integration
def test_accept_policy_unlocks_gated_endpoints(settings) -> None:
    client = _consented_client(settings, accepted=False)
    assert client.get(GATED).status_code == 403

    response = client.post(ACCEPT, CONSENTS, format="json")

    assert response.status_code == 204
    assert client.get(GATED).status_code == 200
    user = get_user_model().objects.get(email="user@example.com")
    assert user.accepted_policy_version == "2026-07-18"


@pytest.mark.django_db
@pytest.mark.integration
def test_accept_policy_requires_both_flags(settings) -> None:
    client = _consented_client(settings, accepted=False)

    response = client.post(ACCEPT, {"accept_terms": True}, format="json")

    assert response.status_code == 400
    assert "accept_health_data" in response.data
    assert PolicyAcceptance.objects.count() == 0


@pytest.mark.django_db
@pytest.mark.integration
def test_accept_policy_is_idempotent(settings) -> None:
    client = _consented_client(settings, accepted=False)

    first = client.post(ACCEPT, CONSENTS, format="json")
    accepted_at = PolicyAcceptance.objects.get().accepted_at
    second = client.post(ACCEPT, CONSENTS, format="json")

    assert first.status_code == second.status_code == 204
    # Still one row, and re-accepting kept the original timestamp — the
    # first affirmative act is the one the audit trail preserves.
    assert PolicyAcceptance.objects.count() == 1
    assert PolicyAcceptance.objects.get().accepted_at == accepted_at


@pytest.mark.django_db
@pytest.mark.integration
def test_policy_version_bump_regates_user(settings) -> None:
    client = _consented_client(settings)
    assert client.get(GATED).status_code == 200

    settings.POLICY_VERSION = "2027-01-01"

    regated = client.get(GATED)
    assert regated.status_code == 403
    assert regated.data["code"] == "policy_consent_required"

    # Re-accepting adds a second audit row instead of overwriting the first.
    assert client.post(ACCEPT, CONSENTS, format="json").status_code == 204
    assert client.get(GATED).status_code == 200
    versions = set(PolicyAcceptance.objects.values_list("policy_version", flat=True))
    assert versions == {"2026-07-18", "2027-01-01"}


@pytest.mark.django_db
@pytest.mark.integration
def test_exempt_endpoints_stay_open_without_consent(settings) -> None:
    # The consent-withdrawal path (DELETE /auth/me) and everything the app
    # needs to reach the consent screen must keep working unconsented.
    settings.POLICY_VERSION = "2026-07-18"
    user = create_user_with_defaults(
        email="ungated@example.com", password="Str0ngPass!word", email_verified=True
    )

    login = APIClient().post(
        "/api/v1/auth/token",
        {"email": user.email, "password": "Str0ngPass!word"},
        format="json",
    )
    assert login.status_code == 200

    client = APIClient()
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {login.data['access']}")
    assert client.get("/api/v1/auth/me").status_code == 200
    assert (
        client.patch("/api/v1/auth/me", {"timezone": "UTC"}, format="json").status_code
        == 200
    )
    refreshed = APIClient().post(
        "/api/v1/auth/refresh", {"refresh": login.data["refresh"]}, format="json"
    )
    assert refreshed.status_code == 200
    deleted = client.delete(
        "/api/v1/auth/me", {"password": "Str0ngPass!word"}, format="json"
    )
    assert deleted.status_code == 204


@pytest.mark.django_db
@pytest.mark.integration
def test_me_reports_policy_versions(settings) -> None:
    client = _consented_client(settings)

    me = client.get("/api/v1/auth/me")

    assert me.status_code == 200
    assert me.data["accepted_policy_version"] == "2026-07-18"
    assert me.data["current_policy_version"] == "2026-07-18"
