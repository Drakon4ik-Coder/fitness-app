from typing import TYPE_CHECKING, TypeAlias

from django.contrib import admin

from nutrients.models import NutrientDefinition

if TYPE_CHECKING:
    NutrientDefinitionAdminBase: TypeAlias = admin.ModelAdmin[NutrientDefinition]
else:
    NutrientDefinitionAdminBase = admin.ModelAdmin


@admin.register(NutrientDefinition)
class NutrientDefinitionAdmin(NutrientDefinitionAdminBase):
    list_display = ("key", "display_name", "unit", "is_user_defined", "owner")
    search_fields = ("key", "display_name", "owner__username", "owner__email")
