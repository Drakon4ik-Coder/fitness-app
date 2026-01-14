from typing import Any

from rest_framework import serializers

from foods.models import FoodItem
from foods.images import images_ok


class FoodItemCompactSerializer(serializers.ModelSerializer):
    image_url = serializers.SerializerMethodField()
    image_small_url = serializers.SerializerMethodField()

    class Meta:
        model = FoodItem
        fields = (
            "id",
            "name",
            "brands",
            "kcal_100g",
            "image_url",
            "image_small_url",
            "barcode",
        )

    def get_image_url(self, obj: FoodItem) -> str | None:
        small_url = self.get_image_small_url(obj)
        if small_url:
            return small_url
        url = obj.image_url.strip() if obj.image_url else ""
        return url or None

    def get_image_small_url(self, obj: FoodItem) -> str | None:
        if not images_ok(obj) or not obj.image_small:
            return None
        return _absolute_file_url(self.context.get("request"), obj.image_small)


class FoodItemSerializer(serializers.ModelSerializer):
    image_url = serializers.SerializerMethodField()
    image_large_url = serializers.SerializerMethodField()
    image_small_url = serializers.SerializerMethodField()

    class Meta:
        model = FoodItem
        fields = (
            "id",
            "source",
            "external_id",
            "barcode",
            "name",
            "brands",
            "image_url",
            "image_large_url",
            "image_small_url",
            "kcal_100g",
            "protein_g_100g",
            "carbs_g_100g",
            "fat_g_100g",
            "sugars_g_100g",
            "fiber_g_100g",
            "salt_g_100g",
            "serving_size_g",
            "content_hash",
            "image_signature",
            "raw_source_json",
            "nutriments_json",
        )

    def get_image_url(self, obj: FoodItem) -> str | None:
        small_url = self.get_image_small_url(obj)
        if small_url:
            return small_url
        url = obj.image_url.strip() if obj.image_url else ""
        return url or None

    def get_image_large_url(self, obj: FoodItem) -> str | None:
        if not images_ok(obj) or not obj.image_large:
            return None
        return _absolute_file_url(self.context.get("request"), obj.image_large)

    def get_image_small_url(self, obj: FoodItem) -> str | None:
        if not images_ok(obj) or not obj.image_small:
            return None
        return _absolute_file_url(self.context.get("request"), obj.image_small)


def _absolute_file_url(request: Any | None, field: Any) -> str:
    url = field.url
    if request is None:
        return url
    return request.build_absolute_uri(url)


class FoodItemIngestSerializer(serializers.Serializer):
    source = serializers.ChoiceField(  # type: ignore[assignment]
        choices=FoodItem.SOURCE_CHOICES, default=FoodItem.SOURCE_OPEN_FOOD_FACTS
    )
    external_id = serializers.CharField(max_length=128)
    barcode = serializers.CharField(max_length=64)
    name = serializers.CharField(max_length=255)
    brands = serializers.CharField(max_length=255, required=False, allow_blank=True)
    image_url = serializers.URLField(required=False, allow_blank=True)
    image_large_url = serializers.URLField(required=False, allow_blank=True)
    image_small_url = serializers.URLField(required=False, allow_blank=True)
    content_hash = serializers.CharField(
        max_length=128, required=False, allow_blank=True
    )
    image_signature = serializers.CharField(
        max_length=128, required=False, allow_blank=True
    )
    kcal_100g = serializers.DecimalField(
        max_digits=8, decimal_places=2, required=False, allow_null=True
    )
    protein_g_100g = serializers.DecimalField(
        max_digits=8, decimal_places=2, required=False, allow_null=True
    )
    carbs_g_100g = serializers.DecimalField(
        max_digits=8, decimal_places=2, required=False, allow_null=True
    )
    fat_g_100g = serializers.DecimalField(
        max_digits=8, decimal_places=2, required=False, allow_null=True
    )
    sugars_g_100g = serializers.DecimalField(
        max_digits=8, decimal_places=2, required=False, allow_null=True
    )
    fiber_g_100g = serializers.DecimalField(
        max_digits=8, decimal_places=2, required=False, allow_null=True
    )
    salt_g_100g = serializers.DecimalField(
        max_digits=8, decimal_places=2, required=False, allow_null=True
    )
    serving_size_g = serializers.DecimalField(
        max_digits=8, decimal_places=2, required=False, allow_null=True
    )
    raw_source_json = serializers.JSONField()
    nutriments_json = serializers.JSONField(required=False, allow_null=True)

    incoming_image_signature: str | None = None
    incoming_image_large_url: str | None = None
    incoming_image_small_url: str | None = None
    image_signature_changed: bool = False

    def save(self, **kwargs: Any) -> FoodItem:
        data = dict(self.validated_data)
        source = data["source"]
        external_id = data["external_id"]
        barcode = data["barcode"]
        large_url = data.pop("image_large_url", None)
        small_url = data.pop("image_small_url", None)
        if isinstance(large_url, str) and large_url.strip():
            data["image_large_source_url"] = large_url.strip()
            self.incoming_image_large_url = large_url.strip()
        if isinstance(small_url, str) and small_url.strip():
            data["image_small_source_url"] = small_url.strip()
            self.incoming_image_small_url = small_url.strip()

        incoming_signature = data.get("image_signature")
        if isinstance(incoming_signature, str):
            incoming_signature = incoming_signature.strip()
            self.incoming_image_signature = (
                incoming_signature if incoming_signature else None
            )
            if not incoming_signature:
                data.pop("image_signature", None)

        incoming_hash = data.get("content_hash")
        if isinstance(incoming_hash, str):
            incoming_hash = incoming_hash.strip()
            if incoming_hash:
                data["content_hash"] = incoming_hash
            else:
                data.pop("content_hash", None)

        by_barcode = FoodItem.objects.filter(barcode=barcode).first()
        by_external = FoodItem.objects.filter(
            source=source, external_id=external_id
        ).first()

        if by_barcode and by_external and by_barcode.id != by_external.id:
            raise serializers.ValidationError(
                {"barcode": "Barcode already belongs to another food item."}
            )

        item = by_barcode or by_external
        previous_signature = item.image_signature if item else None
        if item:
            for field, value in data.items():
                setattr(item, field, value)
            item.save()
        else:
            item = FoodItem.objects.create(**data)

        self.image_signature_changed = bool(self.incoming_image_signature) and (
            self.incoming_image_signature != (previous_signature or "")
        )
        return item


class FoodItemCheckSerializer(serializers.Serializer):
    source = serializers.ChoiceField(  # type: ignore[assignment]
        choices=FoodItem.SOURCE_CHOICES, default=FoodItem.SOURCE_OPEN_FOOD_FACTS
    )
    external_id = serializers.CharField(max_length=128)
    content_hash = serializers.CharField(max_length=128)
    image_signature = serializers.CharField(required=False, allow_blank=True)


class FoodItemCheckResponseSerializer(serializers.Serializer):
    exists = serializers.BooleanField()
    up_to_date = serializers.BooleanField()
    food_item_id = serializers.IntegerField(allow_null=True)
    images_ok = serializers.BooleanField()
