from typing import Any

from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.auth.models import AbstractBaseUser
from django.contrib.auth.password_validation import validate_password
from rest_framework import serializers
from rest_framework.validators import UniqueValidator
from rest_framework_simplejwt.serializers import TokenObtainPairSerializer

from accounts.services import create_user_with_defaults, record_policy_acceptance

User = get_user_model()


class ConsentFlagsSerializer(serializers.Serializer):
    """The two signup consents (KAN-103), shared by registration and the
    post-hoc accept-policy endpoint.

    Two separate flags, both required and both must be true: GDPR Art. 9
    keeps the explicit health-data consent distinguishable from the general
    ToS/privacy acceptance, and Recital 32 forbids defaults — so nothing is
    optional and false is a field error, not a silent no. These are form
    errors on the user's own signup, not an account-enumeration surface, so
    the messages are deliberately specific (unlike the auth errors).
    """

    accept_terms = serializers.BooleanField(write_only=True)
    accept_health_data = serializers.BooleanField(write_only=True)

    def validate_accept_terms(self, value: bool) -> bool:
        if not value:
            raise serializers.ValidationError(
                "You must accept the Terms of Service and Privacy Policy."
            )
        return value

    def validate_accept_health_data(self, value: bool) -> bool:
        if not value:
            raise serializers.ValidationError(
                "Nutrition tracking needs your consent to process the health "
                "data you log."
            )
        return value


class EmailVerifiedTokenObtainPairSerializer(TokenObtainPairSerializer):
    def validate(self, attrs):
        data = super().validate(attrs)
        if not self.user.email_verified:
            raise serializers.ValidationError(
                "Please confirm your email before signing in."
            )
        return data


class UserRegistrationSerializer(ConsentFlagsSerializer, serializers.ModelSerializer):
    """Signup payload: credentials plus the two consent checkboxes (see
    ConsentFlagsSerializer), recorded as the versioned policy acceptance on
    success (KAN-103)."""

    # Optional at the contract level, unlike the accept-policy endpoint:
    # released builds predate the checkboxes and adding required fields would
    # break their signups (the contract-compat CI gate rightly refuses that).
    # A legacy signup just creates an unconsented account, which every gated
    # endpoint 403s until the in-app consent screen posts accept-policy — the
    # same path Google sign-ins take. A *sent* false is still a hard error
    # (Recital 32: no silent defaults); the inherited validators only run
    # when the key is present.
    accept_terms = serializers.BooleanField(write_only=True, required=False)
    accept_health_data = serializers.BooleanField(write_only=True, required=False)

    password = serializers.CharField(write_only=True, min_length=8)
    email = serializers.EmailField(
        required=True,
        allow_blank=False,
        validators=[
            UniqueValidator(
                queryset=User.objects.all(),
                lookup="iexact",
                message="An account with this email already exists.",
            ),
        ],
    )

    class Meta:
        model = User
        fields = ("id", "email", "password", "accept_terms", "accept_health_data")

    def create(self, validated_data: dict[str, Any]) -> AbstractBaseUser:
        user = create_user_with_defaults(
            email=validated_data["email"],
            password=validated_data["password"],
        )
        # Flags present are validated true above, so the signup checkboxes
        # double as the versioned consent record; flags absent means a legacy
        # build — the account starts unconsented and the blocking consent
        # screen collects it on first open, like Google sign-ins.
        if validated_data.get("accept_terms") and validated_data.get(
            "accept_health_data"
        ):
            record_policy_acceptance(user)
        return user

    def validate_password(self, value: str) -> str:
        user = User(email=self.initial_data.get("email") or "")
        validate_password(value, user=user)
        return value


class UserSerializer(serializers.ModelSerializer):
    # False for OAuth-only accounts. The app uses this to pick the deletion
    # re-auth method: password prompt vs a fresh Google sign-in.
    has_password = serializers.SerializerMethodField()
    # Served alongside accepted_policy_version so the app can compare the two
    # and drive the blocking consent screen (KAN-103) from /auth/me alone.
    current_policy_version = serializers.SerializerMethodField()

    class Meta:
        model = User
        fields = (
            "id",
            "email",
            "username",
            "display_name",
            "timezone",
            "has_password",
            "accepted_policy_version",
            "current_policy_version",
        )

    def get_has_password(self, user) -> bool:
        return user.has_usable_password()

    def get_current_policy_version(self, user) -> str:
        return settings.POLICY_VERSION


class UserUpdateSerializer(serializers.ModelSerializer):
    # The @handle: optional, unset until chosen, null clears it. Shape and
    # case-insensitive uniqueness are enforced here (mirroring the DB's
    # uniq_username_ci constraint) so duplicates 400 instead of 500ing on
    # IntegrityError.
    username = serializers.RegexField(
        r"^[A-Za-z0-9_]{3,20}$",
        required=False,
        allow_null=True,
        error_messages={
            "invalid": "Usernames are 3-20 characters: "
            "letters, numbers and underscores."
        },
        validators=[
            UniqueValidator(
                queryset=User.objects.all(),
                lookup="iexact",
                message="This username is already taken.",
            ),
        ],
    )

    class Meta:
        model = User
        fields = ("display_name", "username", "timezone")
        extra_kwargs = {
            "display_name": {"required": False},
            "timezone": {"required": False},
        }

    def validate_timezone(self, value: str) -> str:
        # Reject unknown zones so _user_zone never silently falls back later.
        from zoneinfo import available_timezones

        if value not in available_timezones():
            raise serializers.ValidationError("Unknown timezone.")
        return value


class GoogleLoginSerializer(serializers.Serializer):
    id_token = serializers.CharField()


class AccountDeleteSerializer(serializers.Serializer):
    """Re-auth proof for DELETE /auth/me: exactly one of the two credentials.

    ``password`` for password accounts; ``id_token`` (a fresh Google ID token)
    for OAuth-only accounts, which have no password to re-enter.
    """

    password = serializers.CharField(required=False, allow_blank=False)
    id_token = serializers.CharField(required=False, allow_blank=False)

    def validate(self, attrs):
        provided = [key for key in ("password", "id_token") if attrs.get(key)]
        if len(provided) != 1:
            raise serializers.ValidationError(
                "Provide exactly one of 'password' or 'id_token'."
            )
        return attrs


class PasswordChangeSerializer(serializers.Serializer):
    """Logged-in password change: re-prove the current password, set a new one.

    The new password is validated in the view (Django's validators need the
    user object for the similarity check).
    """

    current_password = serializers.CharField(allow_blank=False)
    new_password = serializers.CharField(allow_blank=False)


class ResendVerificationSerializer(serializers.Serializer):
    email = serializers.EmailField()


class PasswordResetRequestSerializer(serializers.Serializer):
    email = serializers.EmailField()


class TokenPairSerializer(serializers.Serializer):
    access = serializers.CharField()
    refresh = serializers.CharField()
