from django.contrib import admin

from preferences.models import UserPreferences


@admin.register(UserPreferences)
class UserPreferencesAdmin(admin.ModelAdmin):
    list_display = ("user", "weight_unit", "height_unit", "energy_unit")
    search_fields = ("user__username", "user__email")
