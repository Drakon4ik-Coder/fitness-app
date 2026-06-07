from django.db import migrations, models

import foods.models


def copy_large_image_to_image(apps, schema_editor):
    """Preserve existing full-res images when collapsing to a single field."""
    FoodItem = apps.get_model("foods", "FoodItem")
    for item in FoodItem.objects.all():
        if item.image_large:
            item.image = item.image_large.name
            item.save(update_fields=["image"])


def noop_reverse(apps, schema_editor):
    pass


class Migration(migrations.Migration):
    dependencies = [
        ("foods", "0004_drop_source_urls"),
    ]

    operations = [
        migrations.AddField(
            model_name="fooditem",
            name="image",
            field=models.FileField(
                blank=True,
                null=True,
                upload_to=foods.models.food_image_upload_path,
            ),
        ),
        migrations.RunPython(copy_large_image_to_image, noop_reverse),
        migrations.RemoveField(
            model_name="fooditem",
            name="image_large",
        ),
        migrations.RemoveField(
            model_name="fooditem",
            name="image_small",
        ),
    ]
