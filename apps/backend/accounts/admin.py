from django.contrib import admin
from django.contrib.auth.admin import UserAdmin

from accounts.models import PolicyAcceptance, User


@admin.register(User)
class CustomUserAdmin(UserAdmin):
    ordering = ("email",)
    list_display = ("email", "username", "display_name", "email_verified", "is_staff")
    list_filter = ("email_verified", "is_staff", "is_superuser", "is_active")
    search_fields = ("email", "username", "display_name")

    fieldsets = (
        (None, {"fields": ("email", "password")}),
        (
            "Profile",
            {"fields": ("username", "display_name", "first_name", "last_name")},
        ),
        ("Verification", {"fields": ("email_verified",)}),
        (
            "Permissions",
            {
                "fields": (
                    "is_active",
                    "is_staff",
                    "is_superuser",
                    "groups",
                    "user_permissions",
                )
            },
        ),
        ("Dates", {"fields": ("last_login", "date_joined")}),
    )
    add_fieldsets = (
        (
            None,
            {
                "classes": ("wide",),
                "fields": ("email", "password1", "password2"),
            },
        ),
    )


@admin.register(PolicyAcceptance)
class PolicyAcceptanceAdmin(admin.ModelAdmin):
    """Read-only audit trail of policy consents (KAN-103) — rows are only
    ever written by the consent flows, never edited by hand."""

    list_display = ("user", "policy_version", "accepted_at", "health_consent_at")
    list_filter = ("policy_version",)
    search_fields = ("user__email",)

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False
