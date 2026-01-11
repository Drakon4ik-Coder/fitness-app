from django.db import migrations, models


class Migration(migrations.Migration):
    initial = True

    dependencies = []

    operations = [
        migrations.CreateModel(
            name="FoodItem",
            fields=[
                (
                    "id",
                    models.BigAutoField(
                        auto_created=True,
                        primary_key=True,
                        serialize=False,
                        verbose_name="ID",
                    ),
                ),
                (
                    "source",
                    models.CharField(
                        choices=[("openfoodfacts", "Open Food Facts")],
                        default="openfoodfacts",
                        max_length=32,
                    ),
                ),
                ("external_id", models.CharField(max_length=128)),
                (
                    "barcode",
                    models.CharField(max_length=64, unique=True, db_index=True),
                ),
                ("name", models.CharField(max_length=255)),
                ("brands", models.CharField(blank=True, max_length=255)),
                ("image_url", models.URLField(blank=True)),
                (
                    "kcal_100g",
                    models.DecimalField(
                        blank=True, decimal_places=2, max_digits=8, null=True
                    ),
                ),
                (
                    "protein_g_100g",
                    models.DecimalField(
                        blank=True, decimal_places=2, max_digits=8, null=True
                    ),
                ),
                (
                    "carbs_g_100g",
                    models.DecimalField(
                        blank=True, decimal_places=2, max_digits=8, null=True
                    ),
                ),
                (
                    "fat_g_100g",
                    models.DecimalField(
                        blank=True, decimal_places=2, max_digits=8, null=True
                    ),
                ),
                (
                    "sugars_g_100g",
                    models.DecimalField(
                        blank=True, decimal_places=2, max_digits=8, null=True
                    ),
                ),
                (
                    "fiber_g_100g",
                    models.DecimalField(
                        blank=True, decimal_places=2, max_digits=8, null=True
                    ),
                ),
                (
                    "salt_g_100g",
                    models.DecimalField(
                        blank=True, decimal_places=2, max_digits=8, null=True
                    ),
                ),
                (
                    "serving_size_g",
                    models.DecimalField(
                        blank=True, decimal_places=2, max_digits=8, null=True
                    ),
                ),
                ("raw_source_json", models.JSONField()),
                ("nutriments_json", models.JSONField(blank=True, null=True)),
            ],
        ),
        migrations.AddConstraint(
            model_name="fooditem",
            constraint=models.UniqueConstraint(
                fields=("source", "external_id"),
                name="foods_fooditem_source_external_id_uniq",
            ),
        ),
    ]
