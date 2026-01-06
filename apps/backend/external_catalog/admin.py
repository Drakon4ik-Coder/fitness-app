from typing import TYPE_CHECKING, TypeAlias

from django.contrib import admin

from external_catalog.models import ExternalFoodItemCache

if TYPE_CHECKING:
    ExternalFoodItemCacheAdminBase: TypeAlias = admin.ModelAdmin[ExternalFoodItemCache]
else:
    ExternalFoodItemCacheAdminBase = admin.ModelAdmin


@admin.register(ExternalFoodItemCache)
class ExternalFoodItemCacheAdmin(ExternalFoodItemCacheAdminBase):
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
