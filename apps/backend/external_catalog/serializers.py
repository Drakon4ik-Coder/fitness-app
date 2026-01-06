from typing import TYPE_CHECKING, Any, TypeAlias

from django.utils import timezone
from rest_framework import serializers

from external_catalog.models import ExternalFoodItemCache

if TYPE_CHECKING:
    ExternalFoodItemCacheSerializerBase: TypeAlias = serializers.ModelSerializer[
        ExternalFoodItemCache
    ]
    ExternalFoodItemIngestSerializerBase: TypeAlias = serializers.Serializer[
        ExternalFoodItemCache
    ]
else:
    ExternalFoodItemCacheSerializerBase = serializers.ModelSerializer
    ExternalFoodItemIngestSerializerBase = serializers.Serializer


class ExternalFoodItemCacheSerializer(ExternalFoodItemCacheSerializerBase):
    class Meta:
        model = ExternalFoodItemCache
        fields = (
            "barcode",
            "source",
            "normalized_name",
            "brands",
            "nutriments_json",
            "ingredients_text",
            "image_url",
            "image_urls",
            "last_fetched_at",
            "language",
            "raw_json",
        )


class ExternalFoodItemIngestSerializer(ExternalFoodItemIngestSerializerBase):
    barcode = serializers.CharField(max_length=64)
    raw_json = serializers.JSONField()

    def save(self, **kwargs: object) -> ExternalFoodItemCache:
        barcode = self.validated_data["barcode"]
        raw_json: dict[str, Any] = self.validated_data["raw_json"]
        product = raw_json.get("product") or {}

        normalized_name = (
            product.get("product_name")
            or product.get("product_name_en")
            or product.get("generic_name")
            or ""
        )
        brands = product.get("brands") or ""
        ingredients_text = (
            product.get("ingredients_text") or product.get("ingredients_text_en") or ""
        )
        image_url = product.get("image_url") or product.get("image_front_url") or ""
        nutriments_json = product.get("nutriments") or None
        language = product.get("lang") or raw_json.get("lang") or ""

        image_urls = {}
        for key in (
            "image_url",
            "image_front_url",
            "image_ingredients_url",
            "image_nutrition_url",
        ):
            value = product.get(key)
            if value:
                image_urls[key] = value

        item, _ = ExternalFoodItemCache.objects.update_or_create(
            barcode=barcode,
            defaults={
                "source": ExternalFoodItemCache.SOURCE_OPEN_FOOD_FACTS,
                "raw_json": raw_json,
                "normalized_name": normalized_name,
                "brands": brands,
                "nutriments_json": nutriments_json,
                "ingredients_text": ingredients_text,
                "image_url": image_url,
                "image_urls": image_urls or None,
                "last_fetched_at": timezone.now(),
                "language": language,
            },
        )

        return item
