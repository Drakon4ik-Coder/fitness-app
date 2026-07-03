from decimal import Decimal
from typing import Any

from django.db import IntegrityError, transaction
from rest_framework import serializers

from foods.models import FoodItem
from foods.images import images_ok as _images_ok


class FoodItemCompactSerializer(serializers.ModelSerializer):
    image_url = serializers.SerializerMethodField()

    class Meta:
        model = FoodItem
        fields = (
            "id",
            "source",
            "external_id",
            "name",
            "brands",
            "kcal_100g",
            "image_url",
            "barcode",
        )

    def get_image_url(self, obj: FoodItem) -> str | None:
        if _images_ok(obj) and obj.image:
            return _absolute_file_url(self.context.get("request"), obj.image)
        url = obj.image_url.strip() if obj.image_url else ""
        return url or None


class FoodItemSerializer(serializers.ModelSerializer):
    image_url = serializers.SerializerMethodField()
    images_ok = serializers.SerializerMethodField()

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
            "images_ok",
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
        if _images_ok(obj) and obj.image:
            return _absolute_file_url(self.context.get("request"), obj.image)
        url = obj.image_url.strip() if obj.image_url else ""
        return url or None

    def get_images_ok(self, obj: FoodItem) -> bool:
        return _images_ok(obj)


def _absolute_file_url(request: Any | None, field: Any) -> str:
    url = field.url
    if request is None:
        return url
    return request.build_absolute_uri(url)


# External-catalog sources accepted by the ingest/check flow. Custom foods
# are excluded on purpose: they are owner-scoped and written through the
# /foods/custom endpoint — accepting them here would let any client overwrite
# another user's food by posting its (source, external_id) pair.
_INGEST_SOURCE_CHOICES = [
    (FoodItem.SOURCE_OPEN_FOOD_FACTS, "Open Food Facts"),
]


class FoodItemIngestSerializer(serializers.Serializer):
    source = serializers.ChoiceField(  # type: ignore[assignment]
        choices=_INGEST_SOURCE_CHOICES, default=FoodItem.SOURCE_OPEN_FOOD_FACTS
    )
    external_id = serializers.CharField(max_length=128)
    barcode = serializers.CharField(max_length=64, required=False, allow_blank=True)
    name = serializers.CharField(max_length=255)
    brands = serializers.CharField(max_length=255, required=False, allow_blank=True)
    image_url = serializers.URLField(required=False, allow_blank=True)
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

    def save(self, **kwargs: Any) -> FoodItem:
        data = dict(self.validated_data)
        source = data["source"]
        external_id = data["external_id"]
        # Blank barcodes are stored as NULL (the unique constraint ignores
        # NULLs) and must never be used for lookup: filter(barcode=None)
        # would match any barcode-less row and merge unrelated foods.
        barcode = (data.get("barcode") or "").strip() or None
        data["barcode"] = barcode

        incoming_signature = data.get("image_signature")
        if isinstance(incoming_signature, str):
            incoming_signature = incoming_signature.strip()
            if not incoming_signature:
                data.pop("image_signature", None)
            else:
                data["image_signature"] = incoming_signature

        incoming_hash = data.get("content_hash")
        if isinstance(incoming_hash, str):
            incoming_hash = incoming_hash.strip()
            if incoming_hash:
                data["content_hash"] = incoming_hash
            else:
                data.pop("content_hash", None)

        item: FoodItem | None = None

        def apply_changes(target: FoodItem) -> None:
            for field, value in data.items():
                setattr(target, field, value)

        def resolve_and_save(lock: bool) -> FoodItem:
            queryset = FoodItem.objects.all()
            if lock:
                queryset = queryset.select_for_update()
            by_barcode = queryset.filter(barcode=barcode).first() if barcode else None
            by_external = queryset.filter(
                source=source, external_id=external_id
            ).first()

            if by_barcode and by_external and by_barcode.id != by_external.id:
                raise serializers.ValidationError(
                    {"barcode": "Barcode already belongs to another food item."}
                )

            candidate = by_barcode or by_external
            if candidate:
                apply_changes(candidate)
                candidate.save()
                return candidate
            return FoodItem.objects.create(**data)

        try:
            with transaction.atomic():
                item = resolve_and_save(lock=True)
        except IntegrityError:
            with transaction.atomic():
                item = resolve_and_save(lock=True)

        return item  # type: ignore[return-value]


def _macro_field() -> serializers.DecimalField:
    # Per-100g nutrient amounts are physically bounded by the 100 g itself.
    return serializers.DecimalField(
        max_digits=8,
        decimal_places=2,
        min_value=0,
        max_value=100,
        required=False,
        allow_null=True,
    )


class CustomFoodSerializer(serializers.Serializer):
    """A user's own food, written through an owner-scoped upsert.

    `external_id` is a client-generated UUID: re-posting the same id updates
    the caller's food in place, so the mobile sync path is one idempotent
    POST for both create and edit. Custom foods carry no barcode in v1 —
    barcode-shadowing of OFF items is the override story (KAN-31).
    """

    external_id = serializers.CharField(max_length=128)
    name = serializers.CharField(max_length=255)
    brands = serializers.CharField(
        max_length=255, required=False, allow_blank=True, default=""
    )
    kcal_100g = serializers.DecimalField(
        max_digits=8, decimal_places=2, min_value=0, max_value=900
    )
    protein_g_100g = _macro_field()
    carbs_g_100g = _macro_field()
    fat_g_100g = _macro_field()
    sugars_g_100g = _macro_field()
    fiber_g_100g = _macro_field()
    salt_g_100g = _macro_field()
    serving_size_g = serializers.DecimalField(
        max_digits=8,
        decimal_places=2,
        min_value=Decimal("0.1"),
        max_value=5000,
        required=False,
        allow_null=True,
    )
    nutriments_json = serializers.JSONField(required=False, allow_null=True)

    def save(self, **kwargs: Any) -> FoodItem:
        owner = kwargs["owner"]
        data = dict(self.validated_data)
        external_id = data.pop("external_id")

        with transaction.atomic():
            existing = (
                FoodItem.objects.select_for_update()
                .filter(source=FoodItem.SOURCE_CUSTOM, external_id=external_id)
                .first()
            )
            if existing is not None:
                if existing.owner_id != owner.id:
                    raise serializers.ValidationError(
                        {"external_id": "This id belongs to another user's food."}
                    )
                for field, value in data.items():
                    setattr(existing, field, value)
                existing.save()
                return existing
            return FoodItem.objects.create(
                source=FoodItem.SOURCE_CUSTOM,
                external_id=external_id,
                barcode=None,
                owner=owner,
                raw_source_json={},
                **data,
            )


class FoodItemCheckSerializer(serializers.Serializer):
    source = serializers.ChoiceField(  # type: ignore[assignment]
        choices=_INGEST_SOURCE_CHOICES, default=FoodItem.SOURCE_OPEN_FOOD_FACTS
    )
    external_id = serializers.CharField(max_length=128)
    content_hash = serializers.CharField(max_length=128)
    image_signature = serializers.CharField(required=False, allow_blank=True)


class FoodItemCheckResponseSerializer(serializers.Serializer):
    exists = serializers.BooleanField()
    up_to_date = serializers.BooleanField()
    food_item_id = serializers.IntegerField(allow_null=True)
    images_ok = serializers.BooleanField()
