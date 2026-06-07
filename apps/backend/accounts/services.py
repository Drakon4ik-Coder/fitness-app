import secrets

from django.db import transaction

from accounts.models import User
from preferences.models import UserPreferences


def create_user_with_defaults(
    *,
    email: str,
    password: str | None = None,
    display_name: str | None = None,
    email_verified: bool = False,
) -> User:
    """Create a user with app defaults: a display name and preferences row.

    Shared by password registration and Google sign-in. Passing
    ``password=None`` yields an unusable password (OAuth-only accounts).
    """
    with transaction.atomic():
        user = User.objects.create_user(email=email, password=password)
        user.display_name = display_name or f"User{secrets.token_hex(3)}"
        user.email_verified = email_verified
        user.save(update_fields=["display_name", "email_verified"])
        UserPreferences.objects.get_or_create(user=user)
    return user
