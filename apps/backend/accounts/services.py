import secrets

from django.conf import settings
from django.core.exceptions import ImproperlyConfigured
from django.core.mail import EmailMultiAlternatives
from django.db import transaction
from django.template.loader import render_to_string
from django.urls import reverse

from accounts.models import EmailVerificationToken, PasswordResetToken, User
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


def build_verification_url(raw_token: str, *, request=None) -> str:
    """Absolute URL the user taps to verify, e.g. https://host/.../verify/<token>.

    Prefers the configured PUBLIC_BASE_URL; otherwise derives the host from the
    incoming request. Raises if neither is available, since a relative URL would
    produce a broken, non-clickable link in the verification email.
    """
    path = reverse("verify-email", args=[raw_token])
    if settings.PUBLIC_BASE_URL:
        return f"{settings.PUBLIC_BASE_URL}{path}"
    if request is not None:
        return request.build_absolute_uri(path)
    raise ImproperlyConfigured(
        "Cannot build an absolute verification URL: set PUBLIC_BASE_URL or call "
        "with a request to derive the host."
    )


def send_verification_email(user: User, *, request=None) -> None:
    """Issue a fresh token and email the verification link to ``user``."""
    raw_token = EmailVerificationToken.issue(user)
    verify_url = build_verification_url(raw_token, request=request)
    context = {"verify_url": verify_url, "user": user}

    text_body = render_to_string("accounts/email/verification_email.txt", context)
    html_body = render_to_string("accounts/email/verification_email.html", context)
    message = EmailMultiAlternatives(
        subject="Verify your Symbio email",
        body=text_body,
        from_email=settings.DEFAULT_FROM_EMAIL,
        to=[user.email],
    )
    message.attach_alternative(html_body, "text/html")
    message.send()


def build_password_reset_url(raw_token: str, *, request=None) -> str:
    """Absolute URL the user taps to reset their password.

    Same host-resolution rules as :func:`build_verification_url`: prefer the
    configured PUBLIC_BASE_URL, otherwise derive the host from the request, and
    raise if neither is available rather than email a broken relative link.
    """
    path = reverse("reset-password", args=[raw_token])
    if settings.PUBLIC_BASE_URL:
        return f"{settings.PUBLIC_BASE_URL}{path}"
    if request is not None:
        return request.build_absolute_uri(path)
    raise ImproperlyConfigured(
        "Cannot build an absolute password-reset URL: set PUBLIC_BASE_URL or "
        "call with a request to derive the host."
    )


def send_password_reset_email(user: User, *, request=None) -> None:
    """Issue a fresh token and email the password-reset link to ``user``."""
    raw_token = PasswordResetToken.issue(user)
    reset_url = build_password_reset_url(raw_token, request=request)
    context = {"reset_url": reset_url, "user": user}

    text_body = render_to_string("accounts/email/password_reset_email.txt", context)
    html_body = render_to_string("accounts/email/password_reset_email.html", context)
    message = EmailMultiAlternatives(
        subject="Reset your Symbio password",
        body=text_body,
        from_email=settings.DEFAULT_FROM_EMAIL,
        to=[user.email],
    )
    message.attach_alternative(html_body, "text/html")
    message.send()
