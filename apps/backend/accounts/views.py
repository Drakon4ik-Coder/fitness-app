from typing import TYPE_CHECKING, TypeAlias, cast

from django.contrib.auth.models import AbstractBaseUser
from drf_spectacular.utils import extend_schema
from rest_framework import generics
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from accounts.serializers import UserRegistrationSerializer, UserSerializer

if TYPE_CHECKING:
    RegisterViewBase: TypeAlias = generics.CreateAPIView[AbstractBaseUser]
else:
    RegisterViewBase = generics.CreateAPIView


class RegisterView(RegisterViewBase):
    serializer_class = UserRegistrationSerializer
    permission_classes = [AllowAny]


class MeView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(responses=UserSerializer)
    def get(self, request: Request) -> Response:
        serializer = UserSerializer(cast(AbstractBaseUser, request.user))
        return Response(serializer.data)
