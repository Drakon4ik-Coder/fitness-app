from django.db import migrations

from nutrients.catalog import NUTRIENT_CATALOG


def seed_definitions(apps, schema_editor):
    NutrientDefinition = apps.get_model("nutrients", "NutrientDefinition")
    for spec in NUTRIENT_CATALOG:
        NutrientDefinition.objects.update_or_create(
            key=spec.key,
            defaults={
                "display_name": spec.display_name,
                "unit": spec.unit,
                "is_user_defined": False,
                "owner": None,
            },
        )


def unseed_definitions(apps, schema_editor):
    NutrientDefinition = apps.get_model("nutrients", "NutrientDefinition")
    keys = [spec.key for spec in NUTRIENT_CATALOG]
    NutrientDefinition.objects.filter(key__in=keys, is_user_defined=False).delete()


class Migration(migrations.Migration):
    dependencies = [
        ("nutrients", "0001_initial"),
    ]

    operations = [
        migrations.RunPython(seed_definitions, unseed_definitions),
    ]
