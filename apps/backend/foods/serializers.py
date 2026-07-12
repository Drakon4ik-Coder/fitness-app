from decimal import Decimal
from typing import Any

from django.db import IntegrityError, transaction
from rest_framework import serializers

from foods.images import images_ok as _images_ok
from foods.models import NUTRITION_FIELDS, FoodEditProposal, FoodItem


def nutrition_snapshot(source: FoodItem | dict[str, Any]) -> dict[str, float | None]:
    """Plain-float snapshot of the nutrition columns, JSON-safe."""

    def value_of(field: str) -> Any:
        if isinstance(source, FoodItem):
            return getattr(source, field)
        return source.get(field)

    return {
        field: (None if value_of(field) is None else float(value_of(field)))
        for field in NUTRITION_FIELDS
    }


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
            "overrides_food",
            "community_verified_at",
        )

    overrides_food = serializers.IntegerField(
        source="overrides_id", read_only=True, allow_null=True
    )
    community_verified_at = serializers.DateTimeField(read_only=True, allow_null=True)

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
            "overrides_food",
            "community_verified_at",
        )

    overrides_food = serializers.IntegerField(
        source="overrides_id", read_only=True, allow_null=True
    )
    community_verified_at = serializers.DateTimeField(read_only=True, allow_null=True)

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
            protected: tuple[str, ...] = ()
            if target.community_verified_at is not None:
                # Community-promoted nutrition outranks whatever OFF says now:
                # a client re-ingesting stale OFF data may update names and
                # images, never the verified values (columns or blob).
                protected = (*NUTRITION_FIELDS, "nutriments_json")
            for field, value in data.items():
                if field in protected:
                    continue
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
    # Fork-on-edit: id of the global item this custom food shadows for its
    # owner. Every save against it also records a FoodEditProposal.
    overrides_food = serializers.IntegerField(required=False, allow_null=True)

    def validate_overrides_food(self, value: int | None) -> int | None:
        if value is None:
            return None
        target = FoodItem.objects.filter(pk=value).first()
        if target is None or target.owner_id is not None:
            raise serializers.ValidationError(
                "Overrides must target a global food item."
            )
        return value

    def save(self, **kwargs: Any) -> FoodItem:
        owner = kwargs["owner"]
        data = dict(self.validated_data)
        external_id = data.pop("external_id")
        # Presence, not value: the client omits `overrides_food` to leave an
        # existing override link alone and sends an explicit null to detach it.
        overrides_provided = "overrides_food" in data
        overrides_id = data.pop("overrides_food", None)

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
                # Re-upserting a soft-deleted food revives it.
                existing.deleted_at = None
                if overrides_provided:
                    existing.overrides_id = overrides_id
                existing.save()
                item = existing
            else:
                item = FoodItem.objects.create(
                    source=FoodItem.SOURCE_CUSTOM,
                    external_id=external_id,
                    barcode=None,
                    owner=owner,
                    overrides_id=overrides_id,
                    raw_source_json={},
                    **data,
                )
            self._record_proposal(item, owner)
            return item

    def _record_proposal(self, item: FoodItem, owner: Any) -> None:
        # Every save of an override is one piece of convergence evidence for
        # the shadowed global item (KAN-32 groups these by food + user).
        if item.overrides_id is None:
            return
        target = FoodItem.objects.filter(pk=item.overrides_id).first()
        if target is None:
            return
        FoodEditProposal.objects.create(
            user=owner,
            food_item=target,
            old_values=nutrition_snapshot(target),
            # Snapshot the saved item, not the request payload: an upsert may
            # omit optional nutrients it isn't changing, and a payload
            # snapshot would record those as None — silently withdrawing the
            # user's earlier per-field votes (promotion counts only each
            # user's latest proposal).
            new_values=nutrition_snapshot(item),
        )
        # Opportunistic promotion check: cheap when under quorum, and means
        # convergence takes effect the moment the deciding edit lands.
        from foods.promotion import promote_pending_edits

        promote_pending_edits(target)


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
