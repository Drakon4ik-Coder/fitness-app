from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    initial = True

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name="UserPreferences",
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
                    "weight_unit",
                    models.CharField(
                        choices=[("kg", "kg"), ("lb", "lb")],
                        default="kg",
                        max_length=8,
                    ),
                ),
                (
                    "height_unit",
                    models.CharField(
                        choices=[("cm", "cm"), ("in", "in")],
                        default="cm",
                        max_length=8,
                    ),
                ),
                (
                    "energy_unit",
                    models.CharField(
                        choices=[("kcal", "kcal"), ("kj", "kj")],
                        default="kcal",
                        max_length=8,
                    ),
                ),
                (
                    "daily_calorie_goal",
                    models.PositiveIntegerField(blank=True, null=True),
                ),
                (
                    "weekly_workouts_goal",
                    models.PositiveSmallIntegerField(blank=True, null=True),
                ),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                (
                    "user",
                    models.OneToOneField(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="preferences",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
            ],
        ),
    ]
