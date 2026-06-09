from django.db import migrations, models

import foods.models


def copy_large_image_to_image(apps, schema_editor):
    """Preserve existing full-res images when collapsing to a single field."""
    FoodItem = apps.get_model("foods", "FoodItem")
    db_alias = schema_editor.connection.alias
    for item in FoodItem.objects.using(db_alias).iterator():
        if item.image_large:
            item.image = item.image_large.name
            item.save(using=db_alias, update_fields=["image"])


def copy_image_to_large_image(apps, schema_editor):
    """Restore the full-res image back into image_large when rolling back.

    image_small data cannot be recovered (it was dropped going forward), but
    preserving image_large avoids silently losing image references on reverse.
    """
    FoodItem = apps.get_model("foods", "FoodItem")
    db_alias = schema_editor.connection.alias
    for item in FoodItem.objects.using(db_alias).iterator():
        if item.image:
            item.image_large = item.image.name
            item.save(using=db_alias, update_fields=["image_large"])


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
        migrations.RunPython(copy_large_image_to_image, copy_image_to_large_image),
        migrations.RemoveField(
            model_name="fooditem",
            name="image_large",
        ),
        migrations.RemoveField(
            model_name="fooditem",
            name="image_small",
        ),
    ]
