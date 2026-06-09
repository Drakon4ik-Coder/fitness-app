from django.core.files.base import ContentFile
from django.db import transaction
from django.utils import timezone
from drf_spectacular.utils import OpenApiParameter, OpenApiResponse, extend_schema
from rest_framework.parsers import MultiPartParser
from rest_framework.permissions import IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from foods.models import FoodItem
from foods.images import images_ok, safe_signature, validate_and_normalize_image
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
        from django.db.models import Q

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
        output = FoodItemSerializer(item, context={"request": request})
        return Response(output.data)


class FoodImageUploadView(APIView):
    parser_classes = [MultiPartParser]
    permission_classes = [IsAuthenticated]

    @extend_schema(
        responses={
            200: FoodItemSerializer,
            400: OpenApiResponse(description="Invalid image data"),
            401: OpenApiResponse(description="Unauthorized"),
            404: OpenApiResponse(description="Food item not found"),
        },
    )
    def post(self, request: Request, food_item_id: int) -> Response:
        with transaction.atomic():
            try:
                item = FoodItem.objects.select_for_update().get(pk=food_item_id)
            except FoodItem.DoesNotExist:
                return Response({"detail": "Not found."}, status=404)

            incoming_sig = (request.data.get("image_signature") or "").strip() or None

            max_sig_len = FoodItem._meta.get_field("image_signature").max_length
            if (
                incoming_sig is not None
                and max_sig_len is not None
                and len(incoming_sig) > max_sig_len
            ):
                return Response(
                    {
                        "detail": (
                            f"image_signature must be at most {max_sig_len} characters."
                        )
                    },
                    status=400,
                )

            if images_ok(item) and incoming_sig == item.image_signature:
                return Response(
                    FoodItemSerializer(item, context={"request": request}).data
                )

            image_file = request.FILES.get("image")
            if not image_file:
                return Response({"detail": "image is required."}, status=400)

            try:
                image_bytes = validate_and_normalize_image(
                    image_file.read(), image_file.content_type or ""
                )
            except ValueError as exc:
                return Response({"detail": str(exc)}, status=400)

            sig = safe_signature(incoming_sig)
            if item.image:
                item.image.delete(save=False)
            item.image.save(f"{sig}.jpg", ContentFile(image_bytes), save=False)
            item.image_status = FoodItem.IMAGE_STATUS_OK
            item.image_downloaded_at = timezone.now()
            item.image_signature = incoming_sig
            item.save()

        return Response(FoodItemSerializer(item, context={"request": request}).data)


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
