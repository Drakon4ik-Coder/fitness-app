import logging

from drf_spectacular.utils import extend_schema
from rest_framework import generics, status
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.serializers import BaseSerializer
from rest_framework.views import APIView
from rest_framework_simplejwt.views import TokenObtainPairView
from rest_framework_simplejwt.tokens import RefreshToken
from django.conf import settings
from django.contrib.auth import get_user_model
from django.db import IntegrityError
from django.http import HttpRequest, HttpResponse
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.http import require_http_methods
from google.auth import exceptions as google_exceptions
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token as google_id_token

from accounts.models import EmailVerificationToken
from accounts.serializers import (
    UserRegistrationSerializer,
    UserSerializer,
    EmailVerifiedTokenObtainPairSerializer,
    GoogleLoginSerializer,
    ResendVerificationSerializer,
    TokenPairSerializer,
)
from accounts.services import create_user_with_defaults, send_verification_email

logger = logging.getLogger(__name__)

User = get_user_model()


class GoogleLoginView(APIView):
    permission_classes = [AllowAny]

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

        # If the email is already in use, let the user in and verify it.
        if not user.email_verified:
            user.email_verified = True
            user.save(update_fields=["email_verified"])

        # Mint OUR tokens — same shape as /token.
        refresh = RefreshToken.for_user(user)
        return Response({"access": str(refresh.access_token), "refresh": str(refresh)})


class EmailVerifiedTokenObtainPairView(TokenObtainPairView):
    serializer_class = EmailVerifiedTokenObtainPairSerializer


class RegisterView(generics.CreateAPIView):
    serializer_class = UserRegistrationSerializer
    permission_classes = [AllowAny]

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

    # POST: the user explicitly confirmed.
    user = token_obj.user
    if not user.email_verified:
        user.email_verified = True
        user.save(update_fields=["email_verified"])
    token_obj.used_at = timezone.now()
    token_obj.save(update_fields=["used_at"])
    return _verification_result(request, "success")


def _verification_result(request: HttpRequest, result: str) -> HttpResponse:
    return render(request, "accounts/verification_result.html", {"result": result})


class ResendVerificationView(APIView):
    permission_classes = [AllowAny]

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


class MeView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(responses=UserSerializer)
    def get(self, request: Request) -> Response:
        serializer = UserSerializer(request.user)
        return Response(serializer.data)
