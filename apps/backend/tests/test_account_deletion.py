import re
from datetime import timedelta
from decimal import Decimal
from unittest.mock import patch

import pytest
from django.core import mail
from django.test import Client
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import AccountDeletionToken, User
from accounts.services import create_user_with_defaults
from foods.models import FoodItem
from nutrition.models import MealEntry
from preferences.models import UserPreferences

ME_URL = "/api/v1/auth/me"
WEB_URL = "/delete-account"
VERIFY = "accounts.views.google_id_token.verify_oauth2_token"

PASSWORD = "Str0ngPass!word"


def _auth_client(email: str = "doomed@example.com") -> tuple[APIClient, User]:
    user = create_user_with_defaults(email=email, password=PASSWORD)
    user.email_verified = True
    user.save(update_fields=["email_verified"])
    client = APIClient()
    token_response = client.post(
        "/api/v1/auth/token",
        {"email": user.email, "password": PASSWORD},
        format="json",
    )
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token_response.data['access']}")
    return client, user


def _seed_user_data(user: User) -> None:
    """One row of every user-owned kind, to prove the delete cascades."""
    custom_food = FoodItem.objects.create(
        source=FoodItem.SOURCE_CUSTOM,
        external_id="custom-1",
        owner=user,
        name="My custom food",
        kcal_100g=Decimal("100"),
        raw_source_json={},
    )
    MealEntry.objects.create(
        user=user,
        food_item=custom_food,
        quantity_g=Decimal("150"),
        consumed_at=timezone.now(),
    )


# ---------------------------------------------------------------------------
# DELETE /api/v1/auth/me (in-app path)
# ---------------------------------------------------------------------------


@pytest.mark.django_db
@pytest.mark.integration
def test_delete_me_requires_authentication() -> None:
    response = APIClient().delete(ME_URL, {"password": PASSWORD}, format="json")

    assert response.status_code == 401


@pytest.mark.django_db
@pytest.mark.integration
def test_delete_me_with_correct_password_cascades() -> None:
    client, user = _auth_client()
    _seed_user_data(user)

    response = client.delete(ME_URL, {"password": PASSWORD}, format="json")

    assert response.status_code == 204
    assert not User.objects.filter(pk=user.pk).exists()
    assert not UserPreferences.objects.filter(user_id=user.pk).exists()
    assert not MealEntry.objects.filter(user_id=user.pk).exists()
    assert not FoodItem.objects.filter(owner_id=user.pk).exists()


@pytest.mark.django_db
@pytest.mark.integration
def test_delete_me_rejects_wrong_password() -> None:
    client, user = _auth_client()

    response = client.delete(ME_URL, {"password": "not-the-password"}, format="json")

    assert response.status_code == 403
    assert User.objects.filter(pk=user.pk).exists()


@pytest.mark.django_db
@pytest.mark.integration
def test_delete_me_requires_exactly_one_credential() -> None:
    client, user = _auth_client()

    empty = client.delete(ME_URL, {}, format="json")
    both = client.delete(ME_URL, {"password": PASSWORD, "id_token": "x"}, format="json")

    assert empty.status_code == 400
    assert both.status_code == 400
    assert User.objects.filter(pk=user.pk).exists()


def _google_user_client(email: str = "googler@example.com") -> tuple[APIClient, User]:
    """A signed-in OAuth-only account (no usable password)."""
    with patch(
        VERIFY,
        return_value={"aud": "test-client-id", "email": email, "email_verified": True},
    ):
        response = APIClient().post(
            "/api/v1/auth/google", {"id_token": "x"}, format="json"
        )
    client = APIClient()
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {response.data['access']}")
    return client, User.objects.get(email=email)


@pytest.mark.django_db
@pytest.mark.integration
def test_delete_me_google_account_rejects_password_reauth() -> None:
    client, user = _google_user_client()

    # No usable password to check against — any password must fail, not pass.
    response = client.delete(ME_URL, {"password": ""}, format="json")
    response_guess = client.delete(ME_URL, {"password": "guess"}, format="json")

    assert response.status_code == 400  # blank fails validation
    assert response_guess.status_code == 403
    assert User.objects.filter(pk=user.pk).exists()


@pytest.mark.django_db
@pytest.mark.integration
def test_delete_me_with_google_token_for_own_email() -> None:
    client, user = _google_user_client()

    with patch(
        VERIFY,
        return_value={
            "aud": "test-client-id",
            "email": user.email.upper(),  # case must not matter
            "email_verified": True,
        },
    ):
        response = client.delete(ME_URL, {"id_token": "fresh"}, format="json")

    assert response.status_code == 204
    assert not User.objects.filter(pk=user.pk).exists()


@pytest.mark.django_db
@pytest.mark.integration
def test_delete_me_rejects_google_token_for_other_email() -> None:
    client, user = _google_user_client()

    with patch(
        VERIFY,
        return_value={
            "aud": "test-client-id",
            "email": "someone-else@example.com",
            "email_verified": True,
        },
    ):
        response = client.delete(ME_URL, {"id_token": "stolen"}, format="json")

    assert response.status_code == 403
    assert User.objects.filter(pk=user.pk).exists()


@pytest.mark.django_db
@pytest.mark.integration
def test_me_reports_has_password() -> None:
    password_client, _ = _auth_client(email="pw@example.com")
    google_client, _ = _google_user_client(email="oauth@example.com")

    assert password_client.get(ME_URL).data["has_password"] is True
    assert google_client.get(ME_URL).data["has_password"] is False


# ---------------------------------------------------------------------------
# /delete-account (logged-out web path)
# ---------------------------------------------------------------------------


def _extract_deletion_link(body: str) -> str:
    match = re.search(r"http://testserver(/delete-account/[^\s]+)", body)
    assert match, f"no deletion link in email body:\n{body}"
    return match.group(1)


# The request form's per-IP email cap counts in the process-wide cache, which
# outlives a test — each test uses its own client IP so they don't interact.


@pytest.mark.django_db
@pytest.mark.integration
def test_web_deletion_request_rate_limited_per_ip() -> None:
    user = create_user_with_defaults(email="capped@example.com", password=PASSWORD)
    client = Client()

    for _ in range(3):
        client.post(WEB_URL, {"email": user.email}, REMOTE_ADDR="10.9.9.1")
    over_limit = client.post(WEB_URL, {"email": user.email}, REMOTE_ADDR="10.9.9.1")

    # The 4th request gets the same neutral page (no enumeration oracle) but
    # sends nothing.
    assert over_limit.status_code == 200
    assert b"Check your email" in over_limit.content
    assert len(mail.outbox) == 3


def test_deletion_rate_limit_add_race_loser_reads_real_count() -> None:
    """A request that loses the first-request race must not claim count == 1.

    Both racers see incr() raise ValueError; only one add() stores the key.
    The loser has to fall back to incr() on the winner's key — here that
    yields a count over the cap, so it must be denied.
    """
    from django.test import RequestFactory

    from accounts import views

    class _LosingRaceCache:
        def __init__(self) -> None:
            self.incr_calls = 0

        def incr(self, key: str) -> int:
            self.incr_calls += 1
            if self.incr_calls == 1:
                raise ValueError(key)
            return views._DELETION_REQUESTS_PER_HOUR + 1

        def add(self, key: str, value: int, timeout: int | None = None) -> bool:
            return False  # another request stored the key first

    request = RequestFactory().post(WEB_URL, REMOTE_ADDR="10.9.9.42")
    with patch.object(views, "cache", _LosingRaceCache()):
        assert views._deletion_request_allowed(request) is False


def test_deletion_rate_limit_denies_when_key_keeps_vanishing() -> None:
    """If the key disappears again after a lost add() (cache eviction), deny
    instead of granting a fresh window or crashing with ValueError."""
    from django.test import RequestFactory

    from accounts import views

    class _EvictingCache:
        def incr(self, key: str) -> int:
            raise ValueError(key)

        def add(self, key: str, value: int, timeout: int | None = None) -> bool:
            return False

    request = RequestFactory().post(WEB_URL, REMOTE_ADDR="10.9.9.43")
    with patch.object(views, "cache", _EvictingCache()):
        assert views._deletion_request_allowed(request) is False


@pytest.mark.django_db
@pytest.mark.integration
def test_web_deletion_request_page_renders() -> None:
    response = Client().get(WEB_URL)

    assert response.status_code == 200
    assert b"Delete your account" in response.content


@pytest.mark.django_db
@pytest.mark.integration
def test_web_deletion_request_is_enumeration_safe() -> None:
    response = Client().post(
        WEB_URL, {"email": "nobody@example.com"}, REMOTE_ADDR="10.9.9.2"
    )

    assert response.status_code == 200
    assert b"Check your email" in response.content
    assert len(mail.outbox) == 0


@pytest.mark.django_db
@pytest.mark.integration
def test_web_deletion_full_flow() -> None:
    user = create_user_with_defaults(email="web-doomed@example.com", password=PASSWORD)
    _seed_user_data(user)
    client = Client()

    response = client.post(
        WEB_URL, {"email": "WEB-doomed@example.com"}, REMOTE_ADDR="10.9.9.3"
    )

    assert response.status_code == 200
    assert len(mail.outbox) == 1
    link = _extract_deletion_link(str(mail.outbox[0].body))

    # GET only shows the confirmation page — scanners must not delete accounts.
    confirm_page = client.get(link)
    assert confirm_page.status_code == 200
    assert b"Delete this account?" in confirm_page.content
    assert User.objects.filter(pk=user.pk).exists()

    done = client.post(link)
    assert done.status_code == 200
    assert b"Account deleted" in done.content
    assert not User.objects.filter(pk=user.pk).exists()
    assert not MealEntry.objects.filter(user_id=user.pk).exists()

    # The token was consumed (and cascaded away) — the link is dead now.
    again = client.post(link)
    assert b"Invalid link" in again.content


@pytest.mark.django_db
@pytest.mark.integration
def test_web_deletion_expired_token() -> None:
    user = create_user_with_defaults(email="slow@example.com", password=PASSWORD)
    raw = AccountDeletionToken.issue(user)
    AccountDeletionToken.objects.filter(user=user).update(
        created_at=timezone.now() - timedelta(hours=2)
    )

    response = Client().post(f"{WEB_URL}/{raw}")

    assert b"Link expired" in response.content
    assert User.objects.filter(pk=user.pk).exists()


@pytest.mark.django_db
@pytest.mark.integration
def test_web_deletion_skips_inactive_accounts() -> None:
    user = create_user_with_defaults(email="disabled@example.com", password=PASSWORD)
    user.is_active = False
    user.save(update_fields=["is_active"])

    response = Client().post(WEB_URL, {"email": user.email}, REMOTE_ADDR="10.9.9.4")

    assert response.status_code == 200
    assert len(mail.outbox) == 0


@pytest.mark.django_db
@pytest.mark.integration
def test_web_deletion_request_requires_email() -> None:
    response = Client().post(WEB_URL, {"email": "  "})

    assert response.status_code == 200
    assert b"Enter the email address" in response.content
    assert len(mail.outbox) == 0
