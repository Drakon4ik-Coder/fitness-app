from django.contrib import admin

from foods.models import FoodItem


@admin.register(FoodItem)
class FoodItemAdmin(admin.ModelAdmin):
    list_display = ("id", "name", "brands", "barcode", "source")
    search_fields = ("name", "brands", "barcode", "external_id")
    list_filter = ("source",)
