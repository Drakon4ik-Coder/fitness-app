from django.conf import settings
from django.db import migrations, models
import django.utils.timezone


class Migration(migrations.Migration):
    initial = True

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("foods", "0001_initial"),
    ]

    operations = [
        migrations.CreateModel(
            name="MealEntry",
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
                    "meal_type",
                    models.CharField(
                        choices=[
                            ("breakfast", "Breakfast"),
                            ("lunch", "Lunch"),
                            ("dinner", "Dinner"),
                            ("snacks", "Snacks"),
                        ],
                        default="breakfast",
                        max_length=16,
                    ),
                ),
                (
                    "consumed_at",
                    models.DateTimeField(default=django.utils.timezone.now),
                ),
                ("quantity_g", models.DecimalField(decimal_places=2, max_digits=8)),
                (
                    "food_item",
                    models.ForeignKey(
                        on_delete=models.deletion.CASCADE,
                        related_name="meal_entries",
                        to="foods.fooditem",
                    ),
                ),
                (
                    "user",
                    models.ForeignKey(
                        on_delete=models.deletion.CASCADE,
                        related_name="meal_entries",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
            ],
        ),
    ]
