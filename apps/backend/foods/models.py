from django.conf import settings
from django.db import models


def food_image_upload_path(instance: "FoodItem", filename: str) -> str:
    barcode = (instance.barcode or instance.external_id or "unknown").strip()
    safe_barcode = "".join(char for char in barcode if char.isalnum()) or "unknown"
    return f"foods/{safe_barcode}/{filename}"


class FoodItem(models.Model):
    SOURCE_OPEN_FOOD_FACTS = "openfoodfacts"
    SOURCE_CUSTOM = "custom"
    SOURCE_CHOICES = [
        (SOURCE_OPEN_FOOD_FACTS, "Open Food Facts"),
        (SOURCE_CUSTOM, "Custom"),
    ]

    IMAGE_STATUS_OK = "ok"
    IMAGE_STATUS_FAILED = "failed"
    IMAGE_STATUS_NONE = "none"
    IMAGE_STATUS_CHOICES = [
        (IMAGE_STATUS_OK, "OK"),
        (IMAGE_STATUS_FAILED, "Failed"),
        (IMAGE_STATUS_NONE, "None"),
    ]

    source = models.CharField(
        max_length=32,
        choices=SOURCE_CHOICES,
        default=SOURCE_OPEN_FOOD_FACTS,
    )
    external_id = models.CharField(max_length=128)
    # Null for foods without a barcode (user-created customs). NULLs never
    # collide under the unique constraint, unlike the '' they replace.
    barcode = models.CharField(
        max_length=64, unique=True, null=True, blank=True, db_index=True
    )
    # Null = a global item (OFF); set = a user's private custom food, visible
    # only to its owner.
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="custom_foods",
    )
    name = models.CharField(max_length=255)
    brands = models.CharField(max_length=255, blank=True)
    image_url = models.URLField(blank=True)
    content_hash = models.CharField(max_length=128, blank=True, null=True)
    image_signature = models.CharField(max_length=128, blank=True, null=True)
    image = models.FileField(upload_to=food_image_upload_path, blank=True, null=True)
    image_downloaded_at = models.DateTimeField(blank=True, null=True)
    image_status = models.CharField(
        max_length=16,
        choices=IMAGE_STATUS_CHOICES,
        default=IMAGE_STATUS_NONE,
    )
    kcal_100g = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True
    )
    protein_g_100g = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True
    )
    carbs_g_100g = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True
    )
    fat_g_100g = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True
    )
    sugars_g_100g = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True
    )
    fiber_g_100g = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True
    )
    salt_g_100g = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True
    )
    serving_size_g = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True
    )
    raw_source_json = models.JSONField()
    nutriments_json = models.JSONField(null=True, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["source", "external_id"],
                name="foods_fooditem_source_external_id_uniq",
            )
        ]

    def __str__(self) -> str:
        return f"{self.name} ({self.source})"
