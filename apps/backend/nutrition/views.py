from datetime import date
from decimal import Decimal

from django.contrib.auth.models import User
from django.utils import timezone
from drf_spectacular.types import OpenApiTypes
from drf_spectacular.utils import OpenApiParameter, OpenApiResponse, extend_schema
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from nutrition.models import MealEntry
from nutrition.serializers import (
    MealEntryCreateSerializer,
    MealEntrySerializer,
    NutritionDaySerializer,
)
from nutrition.utils import calculate_macros, serialize_decimal


class MealEntryCreateView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(
        request=MealEntryCreateSerializer,
        responses={
            201: MealEntrySerializer,
            400: OpenApiResponse(description="Invalid payload"),
            401: OpenApiResponse(description="Unauthorized"),
        },
    )
    def post(self, request: Request) -> Response:
        serializer = MealEntryCreateSerializer(
            data=request.data, context={"request": request}
        )
        serializer.is_valid(raise_exception=True)
        entry = serializer.save()
        output = MealEntrySerializer(entry)
        return Response(output.data, status=status.HTTP_201_CREATED)


class NutritionDayView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(
        parameters=[
            OpenApiParameter(
                name="date",
                type=OpenApiTypes.DATE,
                required=False,
                description="Date in YYYY-MM-DD format (defaults to today).",
            )
        ],
        responses={
            200: NutritionDaySerializer,
            400: OpenApiResponse(description="Invalid date"),
            401: OpenApiResponse(description="Unauthorized"),
        },
    )
    def get(self, request: Request) -> Response:
        date_raw = request.query_params.get("date")
        if date_raw:
            try:
                target_date = date.fromisoformat(date_raw)
            except ValueError:
                return Response(
                    {"detail": "Invalid date format. Use YYYY-MM-DD."},
                    status=status.HTTP_400_BAD_REQUEST,
                )
        else:
            target_date = timezone.localdate()

        assert isinstance(request.user, User)
        user = request.user
        entries = (
            MealEntry.objects.filter(user=user, consumed_at__date=target_date)
            .select_related("food_item")
            .order_by("consumed_at")
        )

        meals: dict[str, list[MealEntry]] = {
            MealEntry.MEAL_BREAKFAST: [],
            MealEntry.MEAL_LUNCH: [],
            MealEntry.MEAL_DINNER: [],
            MealEntry.MEAL_SNACKS: [],
        }
        totals = {
            "kcal": Decimal("0"),
            "protein_g": Decimal("0"),
            "carbs_g": Decimal("0"),
            "fat_g": Decimal("0"),
        }

        for entry in entries:
            meals[entry.meal_type].append(entry)
            macros = calculate_macros(entry.food_item, entry.quantity_g)
            for key, value in macros.items():
                totals[key] += value

        response_data = {
            "date": target_date,
            "totals": {key: serialize_decimal(value) for key, value in totals.items()},
            "meals": {
                "breakfast": meals[MealEntry.MEAL_BREAKFAST],
                "lunch": meals[MealEntry.MEAL_LUNCH],
                "dinner": meals[MealEntry.MEAL_DINNER],
                "snacks": meals[MealEntry.MEAL_SNACKS],
            },
        }
        serializer = NutritionDaySerializer(response_data)
        return Response(serializer.data)
