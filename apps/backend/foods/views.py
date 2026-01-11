from django.db.models import Q
from drf_spectacular.utils import OpenApiParameter, OpenApiResponse, extend_schema
from rest_framework.permissions import IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from foods.models import FoodItem
from foods.serializers import (
    FoodItemCompactSerializer,
    FoodItemIngestSerializer,
    FoodItemSerializer,
)


class FoodTypeaheadView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(
        parameters=[
            OpenApiParameter(
                name="q",
                required=False,
                type=str,
                description="Search query for name/brands.",
            ),
            OpenApiParameter(
                name="limit",
                required=False,
                type=int,
                description="Max number of items to return (1-50).",
            ),
        ],
        responses={
            200: FoodItemCompactSerializer(many=True),
            401: OpenApiResponse(description="Unauthorized"),
        },
    )
    def get(self, request: Request) -> Response:
        query = request.query_params.get("q", "").strip()
        if not query:
            return Response([])

        limit_raw = request.query_params.get("limit")
        try:
            limit = int(limit_raw) if limit_raw is not None else 10
        except (TypeError, ValueError):
            limit = 10
        limit = max(1, min(limit, 50))

        items = (
            FoodItem.objects.filter(
                Q(name__icontains=query) | Q(brands__icontains=query)
            )
            .order_by("name")
            .distinct()[:limit]
        )
        serializer = FoodItemCompactSerializer(items, many=True)
        return Response(serializer.data)


class FoodIngestView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(
        request=FoodItemIngestSerializer,
        responses={
            200: FoodItemSerializer,
            400: OpenApiResponse(description="Invalid payload"),
            401: OpenApiResponse(description="Unauthorized"),
        },
    )
    def post(self, request: Request) -> Response:
        serializer = FoodItemIngestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        item = serializer.save()
        output = FoodItemSerializer(item)
        return Response(output.data)
