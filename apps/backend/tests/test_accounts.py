import re

import pytest
from django.core import mail
from django.contrib.auth import get_user_model
from django.test import Client
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import EmailVerificationToken
from preferences.models import UserPreferences


@pytest.mark.django_db
@pytest.mark.integration
def test_register_creates_preferences() -> None:
    client = APIClient()
    payload = {
        "password": "Str0ngPass!word",
        "email": "newuser@example.com",
    }

    response = client.post("/api/v1/auth/register", payload, format="json")

    assert response.status_code == 201
    user_id = response.data["id"]
    user = get_user_model().objects.get(id=user_id)
    assert UserPreferences.objects.filter(user=user).exists()
    # Default display name is "User" + secrets.token_hex(3) (6 hex chars).
    assert re.fullmatch(r"User[0-9a-f]{6}", user.display_name)


@pytest.mark.django_db
@pytest.mark.integration
def test_register_rejects_common_password() -> None:
    client = APIClient()
    payload = {
        "password": "password1",
        "email": "weakuser@example.com",
    }

    response = client.post("/api/v1/auth/register", payload, format="json")

    assert response.status_code == 400
    assert "password" in response.data


@pytest.mark.django_db
@pytest.mark.integration
def test_token_and_me_flow() -> None:
    user = get_user_model().objects.create_user(
        email="alice@example.com",
        password="Str0ngPass!word",
        email_verified=True,
    )

    client = APIClient()
    token_response = client.post(
        "/api/v1/auth/token",
        {"email": user.email, "password": "Str0ngPass!word"},
        format="json",
    )

    assert token_response.status_code == 200
    access_token = token_response.data["access"]

    client.credentials(HTTP_AUTHORIZATION=f"Bearer {access_token}")
    me_response = client.get("/api/v1/auth/me")

    assert me_response.status_code == 200
    assert me_response.data["email"] == user.email


@pytest.mark.django_db
@pytest.mark.integration
def test_me_requires_authentication() -> None:
    client = APIClient()

    response = client.get("/api/v1/auth/me")

    assert response.status_code == 401


@pytest.mark.django_db
@pytest.mark.integration
def test_register_sends_verification_email_and_user_starts_unverified() -> None:
    client = APIClient()

    response = client.post(
        "/api/v1/auth/register",
        {"password": "Str0ngPass!word", "email": "verify@example.com"},
        format="json",
    )

    assert response.status_code == 201
    user = get_user_model().objects.get(email="verify@example.com")
    assert user.email_verified is False
    assert EmailVerificationToken.objects.filter(user=user).count() == 1
    assert len(mail.outbox) == 1
    assert "verify@example.com" in mail.outbox[0].to
    # The email carries a working verification link the user can tap.
    assert "/api/v1/auth/verify/" in mail.outbox[0].body


@pytest.mark.django_db
@pytest.mark.integration
def test_unverified_user_cannot_obtain_token() -> None:
    get_user_model().objects.create_user(
        email="pending@example.com", password="Str0ngPass!word"
    )
    client = APIClient()

    response = client.post(
        "/api/v1/auth/token",
        {"email": "pending@example.com", "password": "Str0ngPass!word"},
        format="json",
    )

    assert response.status_code == 400


@pytest.mark.django_db
@pytest.mark.integration
def test_opening_verification_link_does_not_verify_until_confirmed() -> None:
    # A GET (e.g. an email scanner pre-fetching the link) must not verify.
    user = get_user_model().objects.create_user(
        email="getonly@example.com", password="Str0ngPass!word"
    )
    raw_token = EmailVerificationToken.issue(user)
    client = APIClient()

    get_response = client.get(f"/api/v1/auth/verify/{raw_token}")

    assert get_response.status_code == 200  # shows the confirm page
    user.refresh_from_db()
    assert user.email_verified is False
    assert EmailVerificationToken.objects.get(user=user).used_at is None


@pytest.mark.django_db
@pytest.mark.integration
def test_confirming_verification_link_verifies_user_then_token_works() -> None:
    user = get_user_model().objects.create_user(
        email="link@example.com", password="Str0ngPass!word"
    )
    raw_token = EmailVerificationToken.issue(user)
    client = APIClient()

    verify_response = client.post(f"/api/v1/auth/verify/{raw_token}")
    assert verify_response.status_code == 200

    user.refresh_from_db()
    assert user.email_verified is True
    token = EmailVerificationToken.objects.get(user=user)
    assert token.used_at is not None

    token_response = client.post(
        "/api/v1/auth/token",
        {"email": "link@example.com", "password": "Str0ngPass!word"},
        format="json",
    )
    assert token_response.status_code == 200


@pytest.mark.django_db
@pytest.mark.integration
def test_confirming_verification_link_is_single_use() -> None:
    # The token consumption is an atomic conditional UPDATE, so a second
    # confirmation (e.g. a concurrent click) must not re-consume the token.
    user = get_user_model().objects.create_user(
        email="single@example.com", password="Str0ngPass!word"
    )
    raw_token = EmailVerificationToken.issue(user)
    client = APIClient()

    first = client.post(f"/api/v1/auth/verify/{raw_token}")
    assert first.status_code == 200
    assert first.context["result"] == "success"
    first_used_at = EmailVerificationToken.objects.get(user=user).used_at
    assert first_used_at is not None

    second = client.post(f"/api/v1/auth/verify/{raw_token}")
    assert second.status_code == 200
    assert second.context["result"] == "already"
    # used_at is untouched by the losing confirmation.
    assert EmailVerificationToken.objects.get(user=user).used_at == first_used_at


@pytest.mark.django_db
def test_concurrent_confirmation_loses_the_race(monkeypatch) -> None:
    # The test DB is SQLite :memory:, which can't reproduce real row-level
    # concurrency, so we inject the race deterministically: a second request
    # consumes the token AFTER this request passed the "used_at is None" guard
    # but BEFORE it issues its own claim. The fixed view claims with a
    # conditional UPDATE (WHERE used_at IS NULL), so it must lose and render
    # "already". A read-modify-write implementation would blindly overwrite
    # used_at and render "success", failing this test.
    from accounts import views

    user = get_user_model().objects.create_user(
        email="interleave@example.com", password="Str0ngPass!word"
    )
    raw_token = EmailVerificationToken.issue(user)
    pk = EmailVerificationToken.objects.get(user=user).pk
    client = APIClient()

    real_now = timezone.now

    def consume_mid_flight():
        # Stand-in for the winning concurrent request. timezone.now() is first
        # called as the view builds its claim, i.e. right after the guard —
        # exactly the window where the race occurs.
        monkeypatch.setattr(views.timezone, "now", real_now)  # inject once
        EmailVerificationToken.objects.filter(pk=pk, used_at__isnull=True).update(
            used_at=real_now()
        )
        return real_now()

    monkeypatch.setattr(views.timezone, "now", consume_mid_flight)

    response = client.post(f"/api/v1/auth/verify/{raw_token}")

    assert response.status_code == 200
    assert response.context["result"] == "already"


@pytest.mark.django_db
@pytest.mark.integration
def test_verification_confirm_form_works_with_csrf_enforced() -> None:
    # Exercise the real browser path: GET the confirm page to obtain the CSRF
    # token, then POST it back like the rendered form does.
    user = get_user_model().objects.create_user(
        email="csrf@example.com", password="Str0ngPass!word"
    )
    raw_token = EmailVerificationToken.issue(user)
    client = Client(enforce_csrf_checks=True)
    url = f"/api/v1/auth/verify/{raw_token}"

    # A POST without the CSRF token is rejected (403).
    assert client.post(url).status_code == 403

    get_response = client.get(url)
    csrf_token = get_response.context["csrf_token"]
    confirm_response = client.post(url, {"csrfmiddlewaretoken": str(csrf_token)})

    assert confirm_response.status_code == 200
    user.refresh_from_db()
    assert user.email_verified is True


@pytest.mark.django_db
@pytest.mark.integration
def test_invalid_verification_token_does_not_verify() -> None:
    user = get_user_model().objects.create_user(
        email="bad@example.com", password="Str0ngPass!word"
    )
    client = APIClient()

    response = client.get("/api/v1/auth/verify/not-a-real-token")

    assert response.status_code == 200  # renders a friendly "invalid" page
    user.refresh_from_db()
    assert user.email_verified is False


@pytest.mark.django_db
@pytest.mark.integration
def test_expired_verification_token_does_not_verify(settings) -> None:
    from datetime import timedelta

    settings.EMAIL_VERIFICATION_TTL = timedelta(seconds=0)
    user = get_user_model().objects.create_user(
        email="old@example.com", password="Str0ngPass!word"
    )
    raw_token = EmailVerificationToken.issue(user)
    client = APIClient()

    client.get(f"/api/v1/auth/verify/{raw_token}")

    user.refresh_from_db()
    assert user.email_verified is False


@pytest.mark.django_db
@pytest.mark.integration
def test_resend_verification_sends_link_for_unverified_user() -> None:
    get_user_model().objects.create_user(
        email="resend@example.com", password="Str0ngPass!word"
    )
    client = APIClient()

    response = client.post(
        "/api/v1/auth/resend-verification",
        {"email": "resend@example.com"},
        format="json",
    )

    assert response.status_code == 200
    assert len(mail.outbox) == 1


@pytest.mark.django_db
@pytest.mark.integration
def test_register_rejects_case_variant_of_existing_email() -> None:
    # Email login is case-insensitive, so a case-variant must not create a
    # second account — otherwise an iexact lookup (e.g. Google login) could
    # resolve to an arbitrary one of the duplicates.
    get_user_model().objects.create_user(
        email="dup@example.com", password="Str0ngPass!word"
    )
    client = APIClient()

    response = client.post(
        "/api/v1/auth/register",
        {"password": "Str0ngPass!word", "email": "DUP@example.com"},
        format="json",
    )

    assert response.status_code == 400
    assert "email" in response.data
    assert get_user_model().objects.filter(email__iexact="dup@example.com").count() == 1


@pytest.mark.django_db
@pytest.mark.integration
def test_resend_verification_is_silent_for_unknown_email() -> None:
    client = APIClient()

    response = client.post(
        "/api/v1/auth/resend-verification",
        {"email": "ghost@example.com"},
        format="json",
    )

    # 200 with no email sent, so the endpoint can't enumerate accounts.
    assert response.status_code == 200
    assert len(mail.outbox) == 0


@pytest.mark.django_db
@pytest.mark.integration
def test_resend_verification_is_rate_limited(monkeypatch) -> None:
    # The endpoint is anonymous and sends an email on every call, so it must
    # be throttled to block inbox spam / mail-provider cost abuse. DRF binds
    # the rate table as a class attribute at import, so patch it there rather
    # than via the settings fixture (which the throttle never re-reads).
    from django.core.cache import cache
    from rest_framework.throttling import ScopedRateThrottle

    cache.clear()
    monkeypatch.setattr(
        ScopedRateThrottle, "THROTTLE_RATES", {"resend_verification": "2/hour"}
    )
    client = APIClient()

    for _ in range(2):
        ok = client.post(
            "/api/v1/auth/resend-verification",
            {"email": "ghost@example.com"},
            format="json",
        )
        assert ok.status_code == 200

    throttled = client.post(
        "/api/v1/auth/resend-verification",
        {"email": "ghost@example.com"},
        format="json",
    )
    assert throttled.status_code == 429
