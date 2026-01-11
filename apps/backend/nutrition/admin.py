from django.contrib import admin

from nutrition.models import MealEntry


@admin.register(MealEntry)
class MealEntryAdmin(admin.ModelAdmin):
    list_display = ("id", "user", "meal_type", "food_item", "quantity_g", "consumed_at")
    list_filter = ("meal_type",)
    search_fields = ("user__username", "food_item__name", "food_item__barcode")
