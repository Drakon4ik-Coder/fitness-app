from typing import Any

from django.contrib.auth import get_user_model
from django.contrib.auth.password_validation import validate_password
from django.contrib.auth.models import AbstractBaseUser
from rest_framework import serializers
from rest_framework.validators import UniqueValidator
from rest_framework_simplejwt.serializers import TokenObtainPairSerializer
from accounts.services import create_user_with_defaults

User = get_user_model()


class EmailVerifiedTokenObtainPairSerializer(TokenObtainPairSerializer):
    def validate(self, attrs):
        data = super().validate(attrs)
        if not self.user.email_verified:
            raise serializers.ValidationError(
                "Please confirm your email before signing in."
            )
        return data


class UserRegistrationSerializer(serializers.ModelSerializer):
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
        fields = ("id", "email", "password")

    def create(self, validated_data: dict[str, Any]) -> AbstractBaseUser:
        return create_user_with_defaults(
            email=validated_data["email"],
            password=validated_data["password"],
        )

    def validate_password(self, value: str) -> str:
        user = User(email=self.initial_data.get("email") or "")
        validate_password(value, user=user)
        return value


class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ("id", "email", "username", "display_name", "timezone")


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
            "invalid": "Usernames are 3-20 characters: letters, numbers and underscores."
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


class ResendVerificationSerializer(serializers.Serializer):
    email = serializers.EmailField()


class PasswordResetRequestSerializer(serializers.Serializer):
    email = serializers.EmailField()


class TokenPairSerializer(serializers.Serializer):
    access = serializers.CharField()
    refresh = serializers.CharField()
