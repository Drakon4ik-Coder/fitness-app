from unittest.mock import patch

import pytest
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient

from accounts.services import create_user_with_defaults
from preferences.models import UserPreferences

VERIFY = "accounts.views.google_id_token.verify_oauth2_token"
URL = "/api/v1/auth/google"


def _claims(**overrides):
    data = {
        "aud": "test-client-id",
        "email": "googler@example.com",
        "email_verified": True,
        "name": "Goog Ler",
    }
    data.update(overrides)
    return data


@pytest.mark.django_db
@pytest.mark.integration
def test_google_login_creates_new_user() -> None:
    with patch(VERIFY, return_value=_claims()):
        response = APIClient().post(URL, {"id_token": "x"}, format="json")

    assert response.status_code == 200
    assert "access" in response.data and "refresh" in response.data
    user = get_user_model().objects.get(email="googler@example.com")
    assert user.email_verified is True
    assert user.has_usable_password() is False  # OAuth-only account
    assert user.display_name == "Goog Ler"  # from Google's name claim
    assert UserPreferences.objects.filter(user=user).exists()


@pytest.mark.django_db
@pytest.mark.integration
def test_google_login_links_existing_account() -> None:
    existing = create_user_with_defaults(
        email="dup@example.com",
        password="Str0ngPass!word",
        email_verified=False,
    )
    with patch(VERIFY, return_value=_claims(email="dup@example.com")):
        response = APIClient().post(URL, {"id_token": "x"}, format="json")

    assert response.status_code == 200
    assert get_user_model().objects.filter(email="dup@example.com").count() == 1
    existing.refresh_from_db()
    assert existing.email_verified is True  # promoted by Google


@pytest.mark.django_db
@pytest.mark.integration
def test_google_login_rejects_unverified_email() -> None:
    with patch(VERIFY, return_value=_claims(email_verified=False)):
        response = APIClient().post(URL, {"id_token": "x"}, format="json")
    assert response.status_code == 401
    assert get_user_model().objects.count() == 0


@pytest.mark.django_db
@pytest.mark.integration
def test_google_login_rejects_wrong_audience() -> None:
    with patch(VERIFY, return_value=_claims(aud="someone-elses-app")):
        response = APIClient().post(URL, {"id_token": "x"}, format="json")
    assert response.status_code == 401


@pytest.mark.django_db
@pytest.mark.integration
def test_google_login_rejects_invalid_token() -> None:
    with patch(VERIFY, side_effect=ValueError("bad signature")):
        response = APIClient().post(URL, {"id_token": "x"}, format="json")
    assert response.status_code == 401
