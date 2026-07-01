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

    def create(self, validated_data: dict[str, Any]) -> MealEntry:
        request = self.context.get("request")
        user = getattr(request, "user", None)
        if user is None or user.is_anonymous:
            raise serializers.ValidationError({"detail": "Authentication required."})
        return MealEntry.objects.create(user=user, **validated_data)


class MealEntryUpdateSerializer(serializers.ModelSerializer):
    class Meta:
        model = MealEntry
        fields = ("meal_type", "quantity_g")
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
        fields = (
            "id",
            "meal_type",
            "consumed_at",
            "quantity_g",
            "food_item",
            "kcal",
        )

    def get_kcal(self, obj: MealEntry) -> float:
        macros = calculate_macros(obj.food_item, obj.quantity_g)
        return serialize_decimal(macros["kcal"])


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
