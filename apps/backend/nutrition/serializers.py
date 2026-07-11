from typing import Any

from rest_framework import serializers

from foods.models import FoodItem
from foods.serializers import FoodItemSerializer
from nutrition.models import MealEntry
from nutrition.utils import calculate_macros, serialize_decimal


class MealEntryCreateSerializer(serializers.Serializer):
    food_item_id = serializers.PrimaryKeyRelatedField(
        queryset=FoodItem.objects.all(), source="food_item"
    )
    meal_type = serializers.ChoiceField(choices=MealEntry.MEAL_TYPE_CHOICES)
    quantity_g = serializers.DecimalField(max_digits=8, decimal_places=2)
    consumed_at = serializers.DateTimeField(required=False)
    # Client-generated stable id (KAN-28). When an offline create replays, the
    # view dedupes on it instead of inserting a second row.
    client_uuid = serializers.UUIDField(required=False)
    # LWW mutation time of the create. A re-create minted *after* an entry's
    # tombstone resurrects it in place of duplicating or bouncing off the
    # dedupe (KAN-39 undo); on a fresh row it becomes the stored updated_at so
    # edits queued behind the create keep their LWW order (KAN-28). Write-only
    # input; the view pops it and passes the clamped time to save().
    client_updated_at = serializers.DateTimeField(required=False, write_only=True)

    def create(self, validated_data: dict[str, Any]) -> MealEntry:
        request = self.context.get("request")
        user = getattr(request, "user", None)
        if user is None or user.is_anonymous:
            raise serializers.ValidationError({"detail": "Authentication required."})
        return MealEntry.objects.create(user=user, **validated_data)


class MealEntryUpdateSerializer(serializers.ModelSerializer):
    # LWW mutation time (KAN-28): when a replayed offline edit carries this, the
    # view drops the write if the entry already has a newer change. Write-only
    # input; never rendered.
    client_updated_at = serializers.DateTimeField(required=False, write_only=True)

    class Meta:
        model = MealEntry
        fields = ("meal_type", "quantity_g", "client_updated_at")
        extra_kwargs = {
            "meal_type": {"required": False},
            "quantity_g": {"required": False},
        }

    def validate_quantity_g(self, value: Any) -> Any:
        if value is not None and value <= 0:
            raise serializers.ValidationError("Quantity must be greater than zero.")
        return value


class MealEntrySerializer(serializers.ModelSerializer):
    food_item = FoodItemSerializer()
    kcal = serializers.SerializerMethodField()

    class Meta:
        model = MealEntry
        # Variable-length so SyncEntrySerializer.Meta may extend it.
        fields: tuple[str, ...] = (
            "id",
            "client_uuid",
            "meal_type",
            "consumed_at",
            "quantity_g",
            "food_item",
            "kcal",
            "updated_at",
        )

    def get_kcal(self, obj: MealEntry) -> float:
        macros = calculate_macros(obj.food_item, obj.quantity_g)
        return serialize_decimal(macros["kcal"])


class SyncEntrySerializer(MealEntrySerializer):
    """Delta-feed shape: a regular entry plus its tombstone flag.

    Tombstones keep their full payload (the food_item join is already loaded);
    clients only need `deleted` to drop the row locally.
    """

    deleted = serializers.SerializerMethodField()

    class Meta(MealEntrySerializer.Meta):
        fields = MealEntrySerializer.Meta.fields + ("deleted",)

    def get_deleted(self, obj: MealEntry) -> bool:
        return obj.deleted_at is not None


class SyncPageSerializer(serializers.Serializer):
    entries = SyncEntrySerializer(many=True)
    # Opaque to clients: echo back as `since` on the next pull.
    next_cursor = serializers.CharField()
    has_more = serializers.BooleanField()


class NutritionTotalsSerializer(serializers.Serializer):
    kcal = serializers.FloatField()
    protein_g = serializers.FloatField()
    carbs_g = serializers.FloatField()
    fat_g = serializers.FloatField()


class NutritionMealsSerializer(serializers.Serializer):
    breakfast = MealEntrySerializer(many=True)
    lunch = MealEntrySerializer(many=True)
    dinner = MealEntrySerializer(many=True)
    snacks = MealEntrySerializer(many=True)


class NutrientAmountSerializer(serializers.Serializer):
    amount = serializers.FloatField()
    unit = serializers.CharField()
    group = serializers.CharField()
    # Foods that reported this nutrient vs foods logged that day. reported < total
    # means the total is a floor ("incomplete") for completeness-tracked nutrients.
    reported = serializers.IntegerField()
    total = serializers.IntegerField()


class NutritionDaySerializer(serializers.Serializer):
    date = serializers.DateField()
    totals = NutritionTotalsSerializer()
    # Generic breakdown across the curated nutrient catalog (macros, vitamins,
    # minerals, ...). Additive alongside `totals`; only nutrients with data for
    # the day appear. Absent from a food's data -> absent here ("no data").
    nutrients = serializers.DictField(child=NutrientAmountSerializer())
    meals = NutritionMealsSerializer()


class MealTimeStatSerializer(serializers.Serializer):
    typical_hour = serializers.FloatField()
    half_width = serializers.FloatField()
    sample_count = serializers.IntegerField()


class MealTimesSerializer(serializers.Serializer):
    # Only meals with enough history appear; absent meals fall back to the
    # client's population defaults.
    meal_times = serializers.DictField(child=MealTimeStatSerializer())
