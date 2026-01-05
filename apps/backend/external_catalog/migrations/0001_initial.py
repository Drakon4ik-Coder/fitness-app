from django.db import migrations, models
import django.utils.timezone


class Migration(migrations.Migration):
    initial = True

    dependencies = []

    operations = [
        migrations.CreateModel(
            name="ExternalFoodItemCache",
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
                ("barcode", models.CharField(max_length=64, unique=True)),
                (
                    "source",
                    models.CharField(
                        choices=[("openfoodfacts", "Open Food Facts")],
                        default="openfoodfacts",
                        max_length=32,
                    ),
                ),
                ("raw_json", models.JSONField()),
                ("normalized_name", models.CharField(blank=True, max_length=255)),
                ("brands", models.CharField(blank=True, max_length=255)),
                ("nutriments_json", models.JSONField(blank=True, null=True)),
                ("ingredients_text", models.TextField(blank=True)),
                ("image_url", models.URLField(blank=True)),
                ("image_urls", models.JSONField(blank=True, null=True)),
                (
                    "last_fetched_at",
                    models.DateTimeField(default=django.utils.timezone.now),
                ),
                ("language", models.CharField(blank=True, max_length=16)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
        ),
    ]
