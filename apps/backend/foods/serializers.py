from typing import Any

from rest_framework import serializers

from foods.models import FoodItem


class FoodItemCompactSerializer(serializers.ModelSerializer):
    class Meta:
        model = FoodItem
        fields = ("id", "name", "brands", "kcal_100g", "image_url", "barcode")


class FoodItemSerializer(serializers.ModelSerializer):
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
            "kcal_100g",
            "protein_g_100g",
            "carbs_g_100g",
            "fat_g_100g",
            "sugars_g_100g",
            "fiber_g_100g",
            "salt_g_100g",
            "serving_size_g",
            "raw_source_json",
            "nutriments_json",
        )


class FoodItemIngestSerializer(serializers.Serializer):
    source = serializers.ChoiceField(  # type: ignore[assignment]
        choices=FoodItem.SOURCE_CHOICES, default=FoodItem.SOURCE_OPEN_FOOD_FACTS
    )
    external_id = serializers.CharField(max_length=128)
    barcode = serializers.CharField(max_length=64)
    name = serializers.CharField(max_length=255)
    brands = serializers.CharField(max_length=255, required=False, allow_blank=True)
    image_url = serializers.URLField(required=False, allow_blank=True)
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
        barcode = data["barcode"]

        by_barcode = FoodItem.objects.filter(barcode=barcode).first()
        by_external = FoodItem.objects.filter(
            source=source, external_id=external_id
        ).first()

        if by_barcode and by_external and by_barcode.id != by_external.id:
            raise serializers.ValidationError(
                {"barcode": "Barcode already belongs to another food item."}
            )

        item = by_barcode or by_external
        if item:
            for field, value in data.items():
                setattr(item, field, value)
            item.save()
            return item

        return FoodItem.objects.create(**data)
