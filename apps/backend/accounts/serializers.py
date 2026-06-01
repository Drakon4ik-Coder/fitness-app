import secrets
from typing import Any

from django.contrib.auth import get_user_model
from django.contrib.auth.password_validation import validate_password
from django.contrib.auth.models import AbstractBaseUser
from rest_framework import serializers
from rest_framework.validators import UniqueValidator
from rest_framework_simplejwt.serializers import TokenObtainPairSerializer

from preferences.models import UserPreferences

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
                message="An account with this email already exists.",
            ),
        ],
    )

    class Meta:
        model = User
        fields = ("id", "email", "password")

    def create(self, validated_data: dict[str, Any]) -> AbstractBaseUser:
        password = validated_data.pop("password")
        user = User.objects.create_user(password=password, **validated_data)
        # Default display name until the user sets one (e.g. "User42").
        user.display_name = f"User{secrets.token_hex(3)}"
        user.save(update_fields=["display_name"])
        UserPreferences.objects.get_or_create(user=user)
        return user

    def validate_password(self, value: str) -> str:
        user = User(email=self.initial_data.get("email") or "")
        validate_password(value, user=user)
        return value


class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ("id", "email", "display_name")
