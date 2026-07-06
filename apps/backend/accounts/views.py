import logging

from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError
from django.db import IntegrityError
from django.http import HttpRequest, HttpResponse
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.http import require_http_methods
from drf_spectacular.utils import extend_schema
from google.auth import exceptions as google_exceptions
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token as google_id_token
from rest_framework import generics, status
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.serializers import BaseSerializer
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.views import TokenObtainPairView

from accounts.models import EmailVerificationToken, PasswordResetToken
from accounts.serializers import (
    EmailVerifiedTokenObtainPairSerializer,
    GoogleLoginSerializer,
    PasswordResetRequestSerializer,
    ResendVerificationSerializer,
    TokenPairSerializer,
    UserRegistrationSerializer,
    UserSerializer,
    UserUpdateSerializer,
)
from accounts.services import (
    create_user_with_defaults,
    send_password_reset_email,
    send_verification_email,
)

logger = logging.getLogger(__name__)

User = get_user_model()


class GoogleLoginView(APIView):
    permission_classes = [AllowAny]
    # Anonymous + makes an outbound call to Google to verify the token on
    # every request, so rate limit by client IP.
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "google"

    @extend_schema(request=GoogleLoginSerializer, responses=TokenPairSerializer)
    def post(self, request: Request) -> Response:
        body = GoogleLoginSerializer(data=request.data)
        body.is_valid(raise_exception=True)
        raw_token = body.validated_data["id_token"]

        # Verify the token is authentic (signature, issuer, expiry).
        try:
            claims = google_id_token.verify_oauth2_token(
                raw_token,
                google_requests.Request(),
                clock_skew_in_seconds=10,
            )
        except google_exceptions.TransportError:
            # Couldn't reach Google to fetch signing certs — transient and
            # not the caller's fault, so don't brand the token as invalid.
            return Response(
                {"detail": "Could not verify Google token, try again later."},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        except (ValueError, google_exceptions.GoogleAuthError):
            # Bad signature/expiry/audience (ValueError) or an untrusted
            # issuer (GoogleAuthError) — reject as an invalid token.
            return Response(
                {"detail": "Invalid Google token."},
                status=status.HTTP_401_UNAUTHORIZED,
            )

        # Verify it was minted for OUR app, and the email is verified.
        if claims.get("aud") not in settings.GOOGLE_OAUTH_CLIENT_IDS:
            return Response(
                {"detail": "Unrecognized Google client."},
                status=status.HTTP_401_UNAUTHORIZED,
            )
        if not claims.get("email_verified"):
            return Response(
                {"detail": "Google email is not verified."},
                status=status.HTTP_401_UNAUTHORIZED,
            )

        # Find-or-create, then link/flip verification as needed.
        email = claims["email"].lower()
        user = User.objects.filter(email__iexact=email).first()
        if user is None:
            try:
                user = create_user_with_defaults(
                    email=email,
                    display_name=claims.get("name"),
                    email_verified=True,
                )
            except IntegrityError:
                # A concurrent login created this user between our lookup
                # and insert; reuse the row that request committed.
                user = User.objects.filter(email__iexact=email).first()
                if user is None:
                    # The conflicting insert didn't ultimately commit.
                    return Response(
                        {"detail": "Could not complete sign-in, try again."},
                        status=status.HTTP_409_CONFLICT,
                    )

        # Deactivated accounts must not be able to sign in, mirroring the
        # is_active check the password flow gets for free via authenticate().
        if not user.is_active:
            return Response(
                {"detail": "This account is disabled."},
                status=status.HTTP_401_UNAUTHORIZED,
            )

        # If the email is already in use, let the user in and verify it.
        if not user.email_verified:
            user.email_verified = True
            user.save(update_fields=["email_verified"])

        # Mint OUR tokens — same shape as /token.
        refresh = RefreshToken.for_user(user)
        return Response({"access": str(refresh.access_token), "refresh": str(refresh)})


class EmailVerifiedTokenObtainPairView(TokenObtainPairView):
    serializer_class = EmailVerifiedTokenObtainPairSerializer
    # Anonymous login — throttle by client IP to blunt credential
    # brute-force / password-spraying.
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "login"


class RegisterView(generics.CreateAPIView):
    serializer_class = UserRegistrationSerializer
    permission_classes = [AllowAny]
    # Anonymous + sends a verification email per call, so rate limit by client
    # IP to block signup spam / mail-provider cost.
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "register"

    def perform_create(self, serializer: BaseSerializer) -> None:
        user = serializer.save()
        try:
            send_verification_email(user, request=self.request)
        except Exception:
            # The account exists; a failed send shouldn't 500 the signup. The
            # user can request a fresh link via the resend endpoint.
            logger.exception("Failed to send verification email to %s", user.email)


@require_http_methods(["GET", "POST"])
def verify_email(request: HttpRequest, token: str) -> HttpResponse:
    """Landing page the emailed link points to.

    A GET only shows a confirmation page; the email is verified on POST (when
    the user clicks the button). This keeps email security scanners, which
    pre-fetch links with GET, from silently consuming the token.
    """
    token_obj = (
        EmailVerificationToken.objects.select_related("user")
        .filter(token_hash=EmailVerificationToken.hash_token(token))
        .first()
    )

    if token_obj is None:
        return _verification_result(request, "invalid")
    if token_obj.used_at is not None:
        # Already consumed by an earlier confirmation; the email is verified.
        return _verification_result(request, "already")
    if token_obj.is_expired:
        return _verification_result(request, "expired")

    if request.method == "GET":
        return render(request, "accounts/verification_confirm.html")

    # POST: the user explicitly confirmed. Consume the token with a single
    # conditional UPDATE so concurrent confirmations can't both succeed: only
    # the request that flips used_at from NULL wins and verifies the email.
    claimed = EmailVerificationToken.objects.filter(
        pk=token_obj.pk, used_at__isnull=True
    ).update(used_at=timezone.now())
    if not claimed:
        # Another concurrent confirmation consumed the token first.
        return _verification_result(request, "already")

    user = token_obj.user
    if not user.email_verified:
        user.email_verified = True
        user.save(update_fields=["email_verified"])
    return _verification_result(request, "success")


def _verification_result(request: HttpRequest, result: str) -> HttpResponse:
    return render(request, "accounts/verification_result.html", {"result": result})


class ResendVerificationView(APIView):
    permission_classes = [AllowAny]
    # Anonymous + sends an email on every call, so rate limit by client IP to
    # block spam/enumeration and avoidable mail-provider cost (rate configured
    # under REST_FRAMEWORK["DEFAULT_THROTTLE_RATES"]).
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "resend_verification"

    @extend_schema(request=ResendVerificationSerializer, responses=None)
    def post(self, request: Request) -> Response:
        body = ResendVerificationSerializer(data=request.data)
        body.is_valid(raise_exception=True)
        email = body.validated_data["email"].lower()

        user = User.objects.filter(email__iexact=email).first()
        if user is not None and not user.email_verified:
            try:
                send_verification_email(user, request=request)
            except Exception:
                logger.exception("Failed to resend verification email to %s", email)

        # Always 200, regardless of whether the email exists or is already
        # verified, so the endpoint can't be used to enumerate accounts.
        return Response(
            {"detail": "If that email needs verifying, a link is on its way."}
        )


class PasswordResetRequestView(APIView):
    permission_classes = [AllowAny]
    # Anonymous + sends an email on every call, so rate limit by client IP to
    # block spam/enumeration and avoidable mail-provider cost.
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "password_reset"

    @extend_schema(request=PasswordResetRequestSerializer, responses=None)
    def post(self, request: Request) -> Response:
        body = PasswordResetRequestSerializer(data=request.data)
        body.is_valid(raise_exception=True)
        email = body.validated_data["email"].lower()

        user = User.objects.filter(email__iexact=email).first()
        # Only active accounts get a link; deactivated users must not be able to
        # regain access this way.
        if user is not None and user.is_active:
            try:
                send_password_reset_email(user, request=request)
            except Exception:
                logger.exception("Failed to send password-reset email to %s", email)

        # Always 200, regardless of whether the email exists, so the endpoint
        # can't be used to enumerate accounts.
        return Response(
            {"detail": "If that email has an account, a reset link is on its way."}
        )


@require_http_methods(["GET", "POST"])
def reset_password(request: HttpRequest, token: str) -> HttpResponse:
    """Landing page the password-reset link points to.

    A GET shows the new-password form; the password is changed on POST. Like
    :func:`verify_email`, no token is consumed on GET so email security
    scanners that pre-fetch links with GET can't invalidate a live reset.
    """
    token_obj = (
        PasswordResetToken.objects.select_related("user")
        .filter(token_hash=PasswordResetToken.hash_token(token))
        .first()
    )

    if token_obj is None:
        return _reset_result(request, "invalid")
    if token_obj.used_at is not None:
        return _reset_result(request, "used")
    if token_obj.is_expired:
        return _reset_result(request, "expired")

    if request.method == "GET":
        return render(request, "accounts/password_reset_form.html")

    # POST: validate the new password before consuming the token, so a weak
    # password just re-renders the form with the token still usable.
    password = request.POST.get("password", "")
    user = token_obj.user

    try:
        validate_password(password, user=user)
    except ValidationError as exc:
        return render(
            request,
            "accounts/password_reset_form.html",
            {"errors": exc.messages},
        )

    # Consume the token with a single conditional UPDATE so concurrent submits
    # can't both succeed: only the request that flips used_at from NULL wins.
    claimed = PasswordResetToken.objects.filter(
        pk=token_obj.pk, used_at__isnull=True
    ).update(used_at=timezone.now())
    if not claimed:
        return _reset_result(request, "used")

    user.set_password(password)
    # Receiving the email proves inbox ownership, so an unverified account
    # becomes verified here — same proof the verification link provides.
    fields = ["password"]
    if not user.email_verified:
        user.email_verified = True
        fields.append("email_verified")
    user.save(update_fields=fields)

    # Invalidate any other outstanding reset links for this user.
    PasswordResetToken.objects.filter(user=user, used_at__isnull=True).update(
        used_at=timezone.now()
    )

    return _reset_result(request, "success")


def _reset_result(request: HttpRequest, result: str) -> HttpResponse:
    return render(request, "accounts/password_reset_result.html", {"result": result})


class MeView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(responses=UserSerializer)
    def get(self, request: Request) -> Response:
        serializer = UserSerializer(request.user)
        return Response(serializer.data)

    @extend_schema(request=UserUpdateSerializer, responses=UserSerializer)
    def patch(self, request: Request) -> Response:
        serializer = UserUpdateSerializer(request.user, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        user = serializer.save()
        return Response(UserSerializer(user).data)
