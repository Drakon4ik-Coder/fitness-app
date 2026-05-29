from typing import Any

from django.contrib.auth import get_user_model
from django.contrib.auth.password_validation import validate_password
from django.contrib.auth.models import AbstractBaseUser
from rest_framework import serializers
from rest_framework.validators import UniqueValidator

from preferences.models import UserPreferences

User = get_user_model()


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
        fields = ("id", "username", "email", "password")

    def create(self, validated_data: dict[str, Any]) -> AbstractBaseUser:
        password = validated_data.pop("password")
        user = User.objects.create_user(password=password, **validated_data)
        UserPreferences.objects.get_or_create(user=user)
        return user

    def validate_password(self, value: str) -> str:
        username = self.initial_data.get("username")
        email = self.initial_data.get("email")
        user_kwargs = {}
        username_field = User.USERNAME_FIELD
        if username:
            user_kwargs[username_field] = username
        if email and username_field != "email":
            user_kwargs["email"] = email
        user = User(**user_kwargs) if user_kwargs else None
        validate_password(value, user=user)
        return value


class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ("id", "username", "email")
