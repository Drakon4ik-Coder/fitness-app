import re

import pytest
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient

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
