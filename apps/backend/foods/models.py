from django.conf import settings
from django.db import models

# The nutrition columns governed by the edit-proposal/promotion flow: they
# are snapshotted into FoodEditProposal rows and frozen against OFF
# re-ingests once community-promoted.
NUTRITION_FIELDS = (
    "kcal_100g",
    "protein_g_100g",
    "carbs_g_100g",
    "fat_g_100g",
    "sugars_g_100g",
    "fiber_g_100g",
    "salt_g_100g",
)


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
    # Soft delete for custom foods: hard-deleting would cascade into the
    # owner's MealEntry history. Deleted items vanish from search but keep
    # past logs intact; re-upserting the same external_id revives the food.
    deleted_at = models.DateTimeField(null=True, blank=True)
    # Fork-on-edit (KAN-31): a custom food may shadow a global item for its
    # owner. The override carries the owner's corrected nutrition; the global
    # row stays untouched for everyone else.
    overrides = models.ForeignKey(
        "self",
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="overridden_by",
    )
    # Set when convergence promotion (KAN-32) replaced this item's nutrition
    # with community-verified values. While set, OFF re-ingests update
    # everything EXCEPT the nutrition fields/blob, so a stale OFF entry can't
    # stomp the promoted truth.
    community_verified_at = models.DateTimeField(null=True, blank=True)
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


class FoodEditProposal(models.Model):
    """One user's nutrition correction to a global food, captured whenever an
    override is created or updated.

    Does nothing on its own — it silently accumulates the evidence that
    convergence promotion (KAN-32) consumes: several independent users
    proposing matching values is what earns an edit shared-truth status.
    """

    STATUS_PENDING = "pending"
    STATUS_PROMOTED = "promoted"
    STATUS_CHOICES = [
        (STATUS_PENDING, "Pending"),
        (STATUS_PROMOTED, "Promoted"),
    ]

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="food_edit_proposals",
    )
    food_item = models.ForeignKey(
        FoodItem,
        on_delete=models.CASCADE,
        related_name="edit_proposals",
    )
    # Nutrition snapshots (plain floats) at proposal time: what the global
    # item said, and what the user's override says instead.
    old_values = models.JSONField()
    new_values = models.JSONField()
    status = models.CharField(
        max_length=16, choices=STATUS_CHOICES, default=STATUS_PENDING
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        indexes = [
            models.Index(fields=["food_item", "status"]),
        ]

    def __str__(self) -> str:
        return f"proposal for {self.food_item_id} by {self.user_id}"
