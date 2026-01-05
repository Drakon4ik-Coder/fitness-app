from django.conf import settings
from django.db import models


class NutrientDefinition(models.Model):
    key = models.CharField(max_length=64, unique=True)
    display_name = models.CharField(max_length=128)
    unit = models.CharField(max_length=32)
    is_user_defined = models.BooleanField(default=False)
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="nutrient_definitions",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"{self.display_name} ({self.key})"
