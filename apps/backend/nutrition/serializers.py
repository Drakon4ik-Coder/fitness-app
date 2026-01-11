from typing import Any

from rest_framework import serializers

from foods.models import FoodItem
from foods.serializers import FoodItemCompactSerializer
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


class MealEntrySerializer(serializers.ModelSerializer):
    food_item = FoodItemCompactSerializer()
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


class NutritionDaySerializer(serializers.Serializer):
    date = serializers.DateField()
    totals = NutritionTotalsSerializer()
    meals = NutritionMealsSerializer()
