from django.contrib import admin

from external_catalog.models import ExternalFoodItemCache


@admin.register(ExternalFoodItemCache)
class ExternalFoodItemCacheAdmin(admin.ModelAdmin):
    list_display = (
        "barcode",
        "source",
        "normalized_name",
        "brands",
        "last_fetched_at",
        "language",
    )
    list_filter = ("source", "language")
    search_fields = ("barcode", "normalized_name", "brands")
