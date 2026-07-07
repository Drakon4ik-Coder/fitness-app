import pytest
from rest_framework.test import APIClient

from accounts.models import User
from preferences.models import UserPreferences


def _auth_client(email: str = "prefsuser@example.com") -> tuple[APIClient, User]:
    user = User.objects.create_user(
        email=email,
        password="Str0ngPass!word",
        email_verified=True,
    )
    client = APIClient()
    token_response = client.post(
        "/api/v1/auth/token",
        {"email": user.email, "password": "Str0ngPass!word"},
        format="json",
    )
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token_response.data['access']}")
    return client, user


@pytest.mark.django_db
@pytest.mark.integration
def test_get_returns_defaults() -> None:
    client, _ = _auth_client()

    response = client.get("/api/v1/preferences/")

    assert response.status_code == 200
    assert response.data["weight_unit"] == "kg"
    assert response.data["energy_unit"] == "kcal"
    assert response.data["daily_calorie_goal"] is None
    assert response.data["nutrient_goals"] == {}


@pytest.mark.django_db
@pytest.mark.integration
def test_get_or_creates_row_for_users_without_one() -> None:
    client, user = _auth_client()
    UserPreferences.objects.filter(user=user).delete()

    response = client.get("/api/v1/preferences/")

    assert response.status_code == 200
    assert UserPreferences.objects.filter(user=user).exists()


@pytest.mark.django_db
@pytest.mark.integration
def test_patch_persists_goals_and_units() -> None:
    client, user = _auth_client()

    response = client.patch(
        "/api/v1/preferences/",
        {
            "energy_unit": "kj",
            "daily_calorie_goal": 2400,
            "nutrient_goals": {"protein": 150, "vitamin_c": 90},
        },
        format="json",
    )

    assert response.status_code == 200
    assert response.data["energy_unit"] == "kj"
    assert response.data["daily_calorie_goal"] == 2400
    assert response.data["nutrient_goals"] == {"protein": 150.0, "vitamin_c": 90.0}
    prefs = UserPreferences.objects.get(user=user)
    assert prefs.nutrient_goals == {"protein": 150.0, "vitamin_c": 90.0}


@pytest.mark.django_db
@pytest.mark.integration
def test_patch_is_partial() -> None:
    client, _ = _auth_client()
    client.patch(
        "/api/v1/preferences/",
        {"nutrient_goals": {"protein": 150}},
        format="json",
    )

    response = client.patch(
        "/api/v1/preferences/",
        {"daily_calorie_goal": 2000},
        format="json",
    )

    assert response.status_code == 200
    # Untouched fields survive a partial update.
    assert response.data["nutrient_goals"] == {"protein": 150.0}
    assert response.data["daily_calorie_goal"] == 2000


@pytest.mark.django_db
@pytest.mark.integration
def test_patch_rejects_unknown_nutrient_key() -> None:
    client, _ = _auth_client()

    response = client.patch(
        "/api/v1/preferences/",
        {"nutrient_goals": {"unobtanium": 10}},
        format="json",
    )

    assert response.status_code == 400


@pytest.mark.django_db
@pytest.mark.integration
def test_patch_rejects_non_positive_goal() -> None:
    client, _ = _auth_client()

    response = client.patch(
        "/api/v1/preferences/",
        {"nutrient_goals": {"protein": 0}},
        format="json",
    )

    assert response.status_code == 400


@pytest.mark.django_db
@pytest.mark.integration
def test_focus_nutrients_default_is_empty() -> None:
    client, _ = _auth_client()

    response = client.get("/api/v1/preferences/")

    assert response.status_code == 200
    assert response.data["focus_nutrients"] == []


@pytest.mark.django_db
@pytest.mark.integration
def test_patch_persists_focus_nutrients_in_order() -> None:
    client, user = _auth_client()

    response = client.patch(
        "/api/v1/preferences/",
        {"focus_nutrients": ["fiber", "protein", "sugars", "sodium"]},
        format="json",
    )

    assert response.status_code == 200
    assert response.data["focus_nutrients"] == ["fiber", "protein", "sugars", "sodium"]
    prefs = UserPreferences.objects.get(user=user)
    assert prefs.focus_nutrients == ["fiber", "protein", "sugars", "sodium"]


@pytest.mark.django_db
@pytest.mark.integration
def test_patch_rejects_bad_focus_nutrients() -> None:
    client, _ = _auth_client()

    too_many = client.patch(
        "/api/v1/preferences/",
        {"focus_nutrients": ["protein", "carbs", "fat", "fiber", "sugars"]},
        format="json",
    )
    unknown = client.patch(
        "/api/v1/preferences/",
        {"focus_nutrients": ["unobtanium"]},
        format="json",
    )
    duplicate = client.patch(
        "/api/v1/preferences/",
        {"focus_nutrients": ["protein", "protein"]},
        format="json",
    )

    assert too_many.status_code == 400
    assert unknown.status_code == 400
    assert duplicate.status_code == 400


@pytest.mark.django_db
@pytest.mark.integration
def test_warn_nutrients_default_is_empty() -> None:
    client, _ = _auth_client()

    response = client.get("/api/v1/preferences/")

    assert response.status_code == 200
    assert response.data["warn_nutrients"] == []


@pytest.mark.django_db
@pytest.mark.integration
def test_patch_persists_warn_nutrients() -> None:
    client, user = _auth_client()

    response = client.patch(
        "/api/v1/preferences/",
        {"warn_nutrients": ["sodium", "sugars", "saturated_fat"]},
        format="json",
    )

    assert response.status_code == 200
    assert response.data["warn_nutrients"] == ["sodium", "sugars", "saturated_fat"]
    prefs = UserPreferences.objects.get(user=user)
    assert prefs.warn_nutrients == ["sodium", "sugars", "saturated_fat"]


@pytest.mark.django_db
@pytest.mark.integration
def test_patch_rejects_bad_warn_nutrients() -> None:
    client, _ = _auth_client()

    unknown = client.patch(
        "/api/v1/preferences/",
        {"warn_nutrients": ["unobtanium"]},
        format="json",
    )
    duplicate = client.patch(
        "/api/v1/preferences/",
        {"warn_nutrients": ["sodium", "sodium"]},
        format="json",
    )
    not_a_list = client.patch(
        "/api/v1/preferences/",
        {"warn_nutrients": {"sodium": True}},
        format="json",
    )

    assert unknown.status_code == 400
    assert duplicate.status_code == 400
    assert not_a_list.status_code == 400


@pytest.mark.django_db
@pytest.mark.integration
def test_requires_authentication() -> None:
    response = APIClient().get("/api/v1/preferences/")

    assert response.status_code == 401
