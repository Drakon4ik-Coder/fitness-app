from drf_spectacular.utils import extend_schema
from rest_framework.permissions import IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from preferences.models import UserPreferences
from preferences.serializers import UserPreferencesSerializer


class PreferencesView(APIView):
    """The signed-in user's preferences: unit choices and daily goals.

    A row is created on registration, but ``get_or_create`` here keeps the
    endpoint robust for accounts predating that (e.g. seeded/imported users).
    """

    permission_classes = [IsAuthenticated]

    def _get_or_create(self, request: Request) -> UserPreferences:
        prefs, _ = UserPreferences.objects.get_or_create(user=request.user)
        return prefs

    @extend_schema(responses=UserPreferencesSerializer)
    def get(self, request: Request) -> Response:
        prefs = self._get_or_create(request)
        return Response(UserPreferencesSerializer(prefs).data)

    @extend_schema(
        request=UserPreferencesSerializer, responses=UserPreferencesSerializer
    )
    def patch(self, request: Request) -> Response:
        prefs = self._get_or_create(request)
        serializer = UserPreferencesSerializer(prefs, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)
