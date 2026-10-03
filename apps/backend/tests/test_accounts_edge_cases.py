"""Edge and failure paths of the accounts app (KAN-131 coverage pass)."""

import logging
from unittest.mock import patch

import pytest
from django.contrib import admin
from django.core.exceptions import ImproperlyConfigured
from django.db import IntegrityError
from django.test import RequestFactory, override_settings
from django.utils import timezone
from google.auth import exceptions as google_exceptions
from rest_framework.test import APIClient

from accounts.models import (
    AccountDeletionToken,
    EmailVerificationToken,
    PasswordResetToken,
    PolicyAcceptance,
    User,
)
from accounts.services import (
    build_account_deletion_url,
    build_password_reset_url,
    build_verification_url,
)

VERIFY = "accounts.views.google_id_token.verify_oauth2_token"
PASSWORD = "Str0ngPass!word"


def _user(email: str = "edge@example.com", **extra: object) -> User:
    return User.objects.create_user(
        email=email, password=PASSWORD, email_verified=True, **extra
    )


def _client_for(user: User) -> APIClient:
    client = APIClient()
    token = client.post(
        "/api/v1/auth/token", {"email": user.email, "password": PASSWORD}, format="json"
    )
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token.data['access']}")
    return client


# --- manager and model basics -------------------------------------------------


@pytest.mark.django_db
def test_create_user_requires_an_email() -> None:
    with pytest.raises(ValueError):
        User.objects.create_user(email="", password=PASSWORD)


@pytest.mark.django_db
def test_create_superuser_sets_and_enforces_staff_flags() -> None:
    admin_user = User.objects.create_superuser(
        email="root@example.com", password=PASSWORD
    )
    assert admin_user.is_staff and admin_user.is_superuser
    with pytest.raises(ValueError):
        User.objects.create_superuser(
            email="half@example.com", password=PASSWORD, is_staff=False
        )


@pytest.mark.django_db
def test_model_strings_name_the_user() -> None:
    user = _user()
    PolicyAcceptance.objects.create(
        user=user,
        policy_version="2026-10",
        accepted_at=timezone.now(),
        health_consent_at=timezone.now(),
    )
    EmailVerificationToken.issue(user)
    PasswordResetToken.issue(user)
    AccountDeletionToken.issue(user)

    assert str(user) == user.email
    assert str(PolicyAcceptance.objects.get(user=user)) == (
        f"{user.email} accepted policy 2026-10"
    )
    assert str(EmailVerificationToken.objects.get(user=user)) == (
        f"verification for {user.email}"
    )
    assert str(PasswordResetToken.objects.get(user=user)) == (
        f"password reset for {user.email}"
    )
    assert str(AccountDeletionToken.objects.get(user=user)) == (
        f"account deletion for {user.email}"
    )


def test_policy_acceptances_are_read_only_in_admin() -> None:
    # The acceptance log is legal evidence: no adding or editing by hand.
    model_admin = admin.site._registry[PolicyAcceptance]
    request = RequestFactory().get("/admin/")
    assert model_admin.has_add_permission(request) is False
    assert model_admin.has_change_permission(request) is False


# --- emailed link builders ------------------------------------------------------


@pytest.mark.parametrize(
    "builder",
    [build_verification_url, build_password_reset_url, build_account_deletion_url],
)
def test_link_builders_prefer_public_base_url(builder) -> None:
    with override_settings(PUBLIC_BASE_URL="https://app.example.com"):
        assert builder("tok").startswith("https://app.example.com/")


@pytest.mark.parametrize(
    "builder",
    [build_verification_url, build_password_reset_url, build_account_deletion_url],
)
def test_link_builders_fall_back_to_the_request_host(builder) -> None:
    request = RequestFactory().get("/", HTTP_HOST="api.example.com")
    with override_settings(PUBLIC_BASE_URL="", ALLOWED_HOSTS=["api.example.com"]):
        assert builder("tok", request=request).startswith("http://api.example.com/")


@pytest.mark.parametrize(
    "builder",
    [build_verification_url, build_password_reset_url, build_account_deletion_url],
)
def test_link_builders_refuse_to_emit_a_relative_link(builder) -> None:
    with override_settings(PUBLIC_BASE_URL=""):
        with pytest.raises(ImproperlyConfigured):
            builder("tok")


# --- a failed email send never fails the request ---------------------------------


@pytest.mark.django_db
@pytest.mark.integration
def test_register_succeeds_when_the_verification_email_fails(
    caplog: pytest.LogCaptureFixture,
) -> None:
    with (
        patch("accounts.views.send_verification_email", side_effect=OSError("smtp")),
        caplog.at_level(logging.ERROR, logger="accounts.views"),
    ):
        response = APIClient().post(
            "/api/v1/auth/register",
            {"email": "new@example.com", "password": PASSWORD, "accept_policy": True},
            format="json",
        )
    assert response.status_code == 201, response.data
    assert "Failed to send verification email" in caplog.text


@pytest.mark.django_db
@pytest.mark.integration
def test_resend_and_reset_stay_200_when_sending_fails(
    caplog: pytest.LogCaptureFixture,
) -> None:
    User.objects.create_user(email="unverified@example.com", password=PASSWORD)
    _user("verified@example.com")
    with (
        patch("accounts.views.send_verification_email", side_effect=OSError("smtp")),
        patch("accounts.views.send_password_reset_email", side_effect=OSError("smtp")),
        caplog.at_level(logging.ERROR, logger="accounts.views"),
    ):
        resend = APIClient().post(
            "/api/v1/auth/resend-verification",
            {"email": "unverified@example.com"},
            format="json",
        )
        reset = APIClient().post(
            "/api/v1/auth/password-reset",
            {"email": "verified@example.com"},
            format="json",
        )
    assert resend.status_code == 200
    assert reset.status_code == 200
    assert "Failed to resend verification email" in caplog.text
    assert "Failed to send password-reset email" in caplog.text


@pytest.mark.django_db
@pytest.mark.integration
def test_web_deletion_request_renders_sent_when_sending_fails(
    caplog: pytest.LogCaptureFixture,
) -> None:
    _user("leaver@example.com")
    with (
        patch(
            "accounts.views.send_account_deletion_email", side_effect=OSError("smtp")
        ),
        caplog.at_level(logging.ERROR, logger="accounts.views"),
    ):
        response = APIClient().post("/delete-account", {"email": "leaver@example.com"})
    assert response.status_code == 200
    assert "Failed to send account-deletion email" in caplog.text


# --- Google sign-in and re-auth failure paths --------------------------------------


@pytest.mark.django_db
@pytest.mark.integration
def test_google_login_conflict_when_the_racing_insert_did_not_commit() -> None:
    claims = {
        "aud": "test-client-id",
        "email": "racer@example.com",
        "email_verified": True,
    }
    with (
        patch(VERIFY, return_value=claims),
        patch("accounts.views.create_user_with_defaults", side_effect=IntegrityError),
    ):
        response = APIClient().post(
            "/api/v1/auth/google", {"id_token": "x"}, format="json"
        )
    assert response.status_code == 409


@pytest.mark.django_db
@pytest.mark.integration
def test_google_login_reuses_the_row_a_racing_request_committed() -> None:
    claims = {
        "aud": "test-client-id",
        "email": "racer2@example.com",
        "email_verified": True,
    }

    def racing_insert(**kwargs: object) -> None:
        _user("racer2@example.com")  # the other request wins the insert
        raise IntegrityError

    with (
        patch(VERIFY, return_value=claims),
        patch("accounts.views.create_user_with_defaults", side_effect=racing_insert),
    ):
        response = APIClient().post(
            "/api/v1/auth/google", {"id_token": "x"}, format="json"
        )
    assert response.status_code == 200
    assert User.objects.filter(email="racer2@example.com").count() == 1


def _google_account() -> tuple[APIClient, User]:
    claims = {"aud": "test-client-id", "email": "g@example.com", "email_verified": True}
    with patch(VERIFY, return_value=claims):
        response = APIClient().post(
            "/api/v1/auth/google", {"id_token": "x"}, format="json"
        )
    client = APIClient()
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {response.data['access']}")
    return client, User.objects.get(email="g@example.com")


@pytest.mark.django_db
@pytest.mark.integration
@pytest.mark.parametrize(
    ("verify_kwargs", "expected_status"),
    [
        ({"side_effect": google_exceptions.TransportError("down")}, 503),
        ({"side_effect": ValueError("bad signature")}, 403),
        ({"return_value": {"aud": "other-app", "email": "g@example.com"}}, 403),
    ],
)
def test_google_reauth_failures_never_delete_the_account(
    verify_kwargs: dict, expected_status: int
) -> None:
    client, user = _google_account()
    with patch(VERIFY, **verify_kwargs):
        response = client.delete("/api/v1/auth/me", {"id_token": "t"}, format="json")
    assert response.status_code == expected_status
    assert User.objects.filter(pk=user.pk).exists()


# --- token edge cases ------------------------------------------------------------


@pytest.mark.django_db
@pytest.mark.integration
def test_verifying_an_already_verified_account_still_succeeds() -> None:
    user = _user("twice@example.com")  # already verified
    raw = EmailVerificationToken.issue(user)
    response = APIClient().get(f"/api/v1/auth/verify/{raw}")
    assert response.status_code == 200
    user.refresh_from_db()
    assert user.email_verified
