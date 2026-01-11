from django.db import models


class FoodItem(models.Model):
    SOURCE_OPEN_FOOD_FACTS = "openfoodfacts"
    SOURCE_CHOICES = [(SOURCE_OPEN_FOOD_FACTS, "Open Food Facts")]

    source = models.CharField(
        max_length=32,
        choices=SOURCE_CHOICES,
        default=SOURCE_OPEN_FOOD_FACTS,
    )
    external_id = models.CharField(max_length=128)
    barcode = models.CharField(max_length=64, unique=True, db_index=True)
    name = models.CharField(max_length=255)
    brands = models.CharField(max_length=255, blank=True)
    image_url = models.URLField(blank=True)
    kcal_100g = models.DecimalField(max_digits=8, decimal_places=2, null=True, blank=True)
    protein_g_100g = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True
    )
    carbs_g_100g = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True
    )
    fat_g_100g = models.DecimalField(max_digits=8, decimal_places=2, null=True, blank=True)
    sugars_g_100g = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True
    )
    fiber_g_100g = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True
    )
    salt_g_100g = models.DecimalField(max_digits=8, decimal_places=2, null=True, blank=True)
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
