from django.contrib import admin

from nutrients.models import NutrientDefinition


@admin.register(NutrientDefinition)
class NutrientDefinitionAdmin(admin.ModelAdmin):
    list_display = ("key", "display_name", "unit", "is_user_defined", "owner")
    search_fields = ("key", "display_name", "owner__username", "owner__email")
