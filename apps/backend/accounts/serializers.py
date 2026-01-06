from typing import TYPE_CHECKING, Any, Protocol, TypeAlias, cast

from django.contrib.auth import get_user_model
from django.contrib.auth.models import AbstractBaseUser
from rest_framework import serializers

from preferences.models import UserPreferences

User = get_user_model()

if TYPE_CHECKING:
    UserModelSerializerBase: TypeAlias = serializers.ModelSerializer[AbstractBaseUser]
else:
    UserModelSerializerBase = serializers.ModelSerializer


class UserManagerProtocol(Protocol):
    def create_user(self, **kwargs: Any) -> AbstractBaseUser: ...


class UserRegistrationSerializer(UserModelSerializerBase):
    password = serializers.CharField(write_only=True, min_length=8)

    class Meta:
        model = User
        fields = ("id", "username", "email", "password")
        extra_kwargs = {
            "email": {"required": False, "allow_blank": True},
        }

    def create(self, validated_data: dict[str, Any]) -> AbstractBaseUser:
        password = validated_data.pop("password")
        manager = cast(UserManagerProtocol, User.objects)
        user = manager.create_user(password=password, **validated_data)
        UserPreferences.objects.get_or_create(user=user)
        return user


class UserSerializer(UserModelSerializerBase):
    class Meta:
        model = User
        fields = ("id", "username", "email", "first_name", "last_name")
