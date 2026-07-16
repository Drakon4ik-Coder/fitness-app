from django.core.files.base import ContentFile
from django.db import transaction
from django.utils import timezone
from drf_spectacular.utils import (
    OpenApiParameter,
    OpenApiResponse,
    OpenApiTypes,
    extend_schema,
)
from rest_framework.parsers import MultiPartParser
from rest_framework.permissions import IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView

from foods import fatsecret
from foods.images import images_ok, safe_signature, validate_and_normalize_image
from foods.models import FoodItem
from foods.serializers import (
    CustomFoodSerializer,
    FoodItemCheckResponseSerializer,
    FoodItemCheckSerializer,
    FoodItemCompactSerializer,
    FoodItemIngestSerializer,
    FoodItemSerializer,
)


def _fatsecret_error_response(exc: Exception) -> Response:
    # Real upstream detail (partner error codes/messages, connection errors)
    # is already logged in foods.fatsecret — only a generic detail crosses
    # the client boundary here.
    if isinstance(exc, fatsecret.FatSecretNotConfigured):
        return Response(
            {"detail": "Food search partner is not configured."}, status=503
        )
    if isinstance(exc, fatsecret.FatSecretUpstreamError):
        if exc.status == 429:
            return Response(
                {"detail": "Food search partner is rate limited."}, status=429
            )
        return Response({"detail": "Food search partner error."}, status=502)
    raise exc


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
            # Global items plus the caller's own custom foods; other users'
            # customs stay private and soft-deleted foods stay gone.
            .filter(Q(owner__isnull=True) | Q(owner=request.user))
            .filter(deleted_at__isnull=True)
            # A global item the caller has overridden is replaced by their
            # override (which matches the owner filter above); everyone else
            # keeps seeing the global row.
            .exclude(
                overridden_by__owner_id=request.user.pk,
                overridden_by__deleted_at__isnull=True,
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


class CustomFoodView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(
        request=CustomFoodSerializer,
        responses={
            200: FoodItemSerializer,
            400: OpenApiResponse(description="Invalid payload"),
            401: OpenApiResponse(description="Unauthorized"),
        },
    )
    def post(self, request: Request) -> Response:
        serializer = CustomFoodSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        item = serializer.save(owner=request.user)
        output = FoodItemSerializer(item, context={"request": request})
        return Response(output.data)


class CustomFoodDetailView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(
        responses={
            204: OpenApiResponse(description="Deleted"),
            401: OpenApiResponse(description="Unauthorized"),
            404: OpenApiResponse(description="Not found"),
        },
    )
    def delete(self, request: Request, food_item_id: int) -> Response:
        # Soft delete: the food disappears from search but logged meals keep
        # their history. 404 for missing AND not-owned alike, so existence of
        # other users' foods never leaks.
        item = FoodItem.objects.filter(
            pk=food_item_id,
            source=FoodItem.SOURCE_CUSTOM,
            owner_id=request.user.pk,
        ).first()
        if item is None:
            return Response({"detail": "Not found."}, status=404)
        if item.deleted_at is None:
            item.deleted_at = timezone.now()
            item.save(update_fields=["deleted_at"])
        return Response(status=204)


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


class FatSecretSearchView(APIView):
    permission_classes = [IsAuthenticated]
    # Shared "fatsecret" scope with FatSecretFoodView: every proxied call
    # spends the app-wide partner quota, so one account must be capped well
    # below the default user rate (see DEFAULT_THROTTLE_RATES) or it can
    # starve the shared budget and 429 every other user.
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "fatsecret"

    @extend_schema(
        parameters=[
            OpenApiParameter(
                name="q",
                required=True,
                type=str,
                description="Search query (restaurant/menu item name).",
            ),
            OpenApiParameter(
                name="page",
                required=False,
                type=int,
                description="Zero-based page number (default 0).",
            ),
            OpenApiParameter(
                name="max_results",
                required=False,
                type=int,
                description="Max results per page, 1-50 (default 10).",
            ),
        ],
        responses={
            200: OpenApiResponse(
                response=OpenApiTypes.OBJECT,
                description="Verbatim FatSecret foods.search JSON passthrough.",
            ),
            400: OpenApiResponse(description="q is required"),
            401: OpenApiResponse(description="Unauthorized"),
            429: OpenApiResponse(description="Food search partner is rate limited"),
            502: OpenApiResponse(description="Food search partner error"),
            503: OpenApiResponse(description="Food search partner is not configured"),
        },
    )
    def get(self, request: Request) -> Response:
        q = request.query_params.get("q", "").strip()
        if not q:
            return Response({"detail": "q is required."}, status=400)

        page_raw = request.query_params.get("page")
        try:
            page = int(page_raw) if page_raw is not None else 0
        except (TypeError, ValueError):
            page = 0
        page = max(0, page)

        max_results_raw = request.query_params.get("max_results")
        try:
            max_results = int(max_results_raw) if max_results_raw is not None else 10
        except (TypeError, ValueError):
            max_results = 10
        max_results = max(1, min(max_results, 50))

        try:
            data = fatsecret.search_foods(q, page=page, max_results=max_results)
        except (
            fatsecret.FatSecretNotConfigured,
            fatsecret.FatSecretUpstreamError,
        ) as exc:
            return _fatsecret_error_response(exc)
        return Response(data)


class FatSecretFoodView(APIView):
    permission_classes = [IsAuthenticated]
    # Same shared "fatsecret" scope as FatSecretSearchView — one partner
    # budget, one bucket.
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "fatsecret"

    @extend_schema(
        responses={
            200: OpenApiResponse(
                response=OpenApiTypes.OBJECT,
                description="Verbatim FatSecret food.get.v4 JSON passthrough.",
            ),
            400: OpenApiResponse(description="food_id must be numeric"),
            401: OpenApiResponse(description="Unauthorized"),
            429: OpenApiResponse(description="Food search partner is rate limited"),
            502: OpenApiResponse(description="Food search partner error"),
            503: OpenApiResponse(description="Food search partner is not configured"),
        },
    )
    def get(self, request: Request, food_id: str) -> Response:
        # isdigit() alone admits Unicode digits ("²", "١٢٣") that FatSecret
        # would reject — misclassifying client garbage as a 502 partner error
        # (and polluting the upstream-error logs). ASCII digits only.
        if not (food_id.isascii() and food_id.isdigit()):
            return Response({"detail": "food_id must be numeric."}, status=400)

        try:
            data = fatsecret.get_food(food_id)
        except (
            fatsecret.FatSecretNotConfigured,
            fatsecret.FatSecretUpstreamError,
        ) as exc:
            return _fatsecret_error_response(exc)
        return Response(data)
