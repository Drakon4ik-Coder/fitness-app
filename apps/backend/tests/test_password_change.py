import pytest
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import PasswordResetToken, User
from accounts.services import create_user_with_defaults

URL = "/api/v1/auth/change-password"
TOKEN_URL = "/api/v1/auth/token"

PASSWORD = "Str0ngPass!word"
NEW_PASSWORD = "An0ther!Passw0rd"


def _auth_client(email: str = "user@example.com") -> tuple[APIClient, User]:
    user = create_user_with_defaults(email=email, password=PASSWORD)
    user.email_verified = True
    user.save(update_fields=["email_verified"])
    client = APIClient()
    token_response = client.post(
        TOKEN_URL, {"email": user.email, "password": PASSWORD}, format="json"
    )
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token_response.data['access']}")
    return client, user


@pytest.mark.django_db
@pytest.mark.integration
def test_change_password_requires_authentication() -> None:
    response = APIClient().post(
        URL,
        {"current_password": PASSWORD, "new_password": NEW_PASSWORD},
        format="json",
    )

    assert response.status_code == 401


@pytest.mark.django_db
@pytest.mark.integration
def test_change_password_success_and_old_password_stops_working() -> None:
    client, user = _auth_client()

    response = client.post(
        URL,
        {"current_password": PASSWORD, "new_password": NEW_PASSWORD},
        format="json",
    )

    assert response.status_code == 204
    fresh = APIClient()
    assert (
        fresh.post(
            TOKEN_URL, {"email": user.email, "password": NEW_PASSWORD}, format="json"
        ).status_code
        == 200
    )
    assert (
        fresh.post(
            TOKEN_URL, {"email": user.email, "password": PASSWORD}, format="json"
        ).status_code
        == 401
    )


@pytest.mark.django_db
@pytest.mark.integration
def test_change_password_wrong_current_password_gets_vague_403() -> None:
    client, user = _auth_client()

    response = client.post(
        URL,
        {"current_password": "not-the-password", "new_password": NEW_PASSWORD},
        format="json",
    )

    assert response.status_code == 403
    assert response.data == {"detail": "Re-authentication failed."}
    user.refresh_from_db()
    assert user.check_password(PASSWORD)


@pytest.mark.django_db
@pytest.mark.integration
def test_change_password_oauth_only_account_gets_the_same_vague_403() -> None:
    # No password at all must be indistinguishable from a wrong one, so a
    # stolen token can't learn which re-auth method the account uses.
    user = create_user_with_defaults(email="oauth@example.com", email_verified=True)
    client = APIClient()
    client.force_authenticate(user=user)

    response = client.post(
        URL,
        {"current_password": "anything", "new_password": NEW_PASSWORD},
        format="json",
    )

    assert response.status_code == 403
    assert response.data == {"detail": "Re-authentication failed."}


@pytest.mark.django_db
@pytest.mark.integration
def test_change_password_rejects_weak_new_password() -> None:
    client, user = _auth_client()

    response = client.post(
        URL,
        {"current_password": PASSWORD, "new_password": "short"},
        format="json",
    )

    assert response.status_code == 400
    assert "new_password" in response.data
    user.refresh_from_db()
    assert user.check_password(PASSWORD)


@pytest.mark.django_db
@pytest.mark.integration
def test_change_password_requires_both_fields() -> None:
    client, _ = _auth_client()

    response = client.post(URL, {"new_password": NEW_PASSWORD}, format="json")

    assert response.status_code == 400
    assert "current_password" in response.data


@pytest.mark.django_db
@pytest.mark.integration
def test_change_password_invalidates_outstanding_reset_tokens() -> None:
    client, user = _auth_client()
    PasswordResetToken.issue(user)
    used_before = PasswordResetToken.objects.filter(
        user=user, used_at__isnull=False
    ).count()
    assert used_before == 0

    response = client.post(
        URL,
        {"current_password": PASSWORD, "new_password": NEW_PASSWORD},
        format="json",
    )

    assert response.status_code == 204
    assert not PasswordResetToken.objects.filter(
        user=user, used_at__isnull=True
    ).exists()
    assert PasswordResetToken.objects.filter(
        user=user, used_at__lte=timezone.now()
    ).exists()
