from typing import TYPE_CHECKING, TypeAlias

from django.contrib import admin

from preferences.models import UserPreferences

if TYPE_CHECKING:
    UserPreferencesAdminBase: TypeAlias = admin.ModelAdmin[UserPreferences]
else:
    UserPreferencesAdminBase = admin.ModelAdmin


@admin.register(UserPreferences)
class UserPreferencesAdmin(UserPreferencesAdminBase):
    list_display = ("user", "weight_unit", "height_unit", "energy_unit")
    search_fields = ("user__username", "user__email")
