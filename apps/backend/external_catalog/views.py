from drf_spectacular.utils import extend_schema
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from external_catalog.models import ExternalFoodItemCache
from external_catalog.serializers import (
    ExternalFoodItemCacheSerializer,
    ExternalFoodItemIngestSerializer,
)


class ExternalFoodItemByBarcodeView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(responses=ExternalFoodItemCacheSerializer)
    def get(self, request: Request, barcode: str) -> Response:
        try:
            item = ExternalFoodItemCache.objects.get(barcode=barcode)
        except ExternalFoodItemCache.DoesNotExist:
            return Response(
                {
                    "detail": "not_found",
                    "fetch_external": True,
                    "source": ExternalFoodItemCache.SOURCE_OPEN_FOOD_FACTS,
                    "barcode": barcode,
                },
                status=status.HTTP_404_NOT_FOUND,
            )

        serializer = ExternalFoodItemCacheSerializer(item)
        return Response(serializer.data)


class ExternalFoodItemIngestView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(
        request=ExternalFoodItemIngestSerializer,
        responses=ExternalFoodItemCacheSerializer,
    )
    def post(self, request: Request) -> Response:
        serializer = ExternalFoodItemIngestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        item = serializer.save()
        output = ExternalFoodItemCacheSerializer(item)
        return Response(output.data)
