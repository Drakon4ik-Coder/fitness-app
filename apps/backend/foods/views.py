from django.db.models import Q
from drf_spectacular.utils import OpenApiParameter, OpenApiResponse, extend_schema
from rest_framework.permissions import IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from foods.models import FoodItem
from foods.images import download_food_images, images_ok, should_download_images
from foods.serializers import (
    FoodItemCheckResponseSerializer,
    FoodItemCheckSerializer,
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
        serializer = FoodItemCompactSerializer(
            items, many=True, context={"request": request}
        )
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
        if should_download_images(item, serializer.image_signature_changed):
            download_food_images(
                item,
                serializer.incoming_image_large_url or item.image_large_source_url,
                serializer.incoming_image_small_url or item.image_small_source_url,
                serializer.incoming_image_signature or item.image_signature,
            )
        output = FoodItemSerializer(item, context={"request": request})
        return Response(output.data)


class FoodCheckView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(
        request=FoodItemCheckSerializer,
        responses={
            200: FoodItemCheckResponseSerializer,
            400: OpenApiResponse(description="Invalid payload"),
            401: OpenApiResponse(description="Unauthorized"),
        },
    )
    def post(self, request: Request) -> Response:
        serializer = FoodItemCheckSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        item = FoodItem.objects.filter(
            source=data["source"], external_id=data["external_id"]
        ).first()
        if item is None:
            return Response(
                {
                    "exists": False,
                    "up_to_date": False,
                    "food_item_id": None,
                    "images_ok": False,
                }
            )

        images_ok_value = images_ok(item)
        signature_matches = (item.image_signature or "") == (
            data.get("image_signature") or ""
        )
        hash_matches = (item.content_hash or "") == data["content_hash"]
        up_to_date = hash_matches and signature_matches and images_ok_value
        return Response(
            {
                "exists": True,
                "up_to_date": up_to_date,
                "food_item_id": item.id,
                "images_ok": images_ok_value,
            }
        )
