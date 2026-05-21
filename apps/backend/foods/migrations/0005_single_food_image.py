from django.db import migrations, models

import foods.models


class Migration(migrations.Migration):
    dependencies = [
        ("foods", "0004_drop_source_urls"),
    ]

    operations = [
        migrations.RemoveField(
            model_name="fooditem",
            name="image_large",
        ),
        migrations.RemoveField(
            model_name="fooditem",
            name="image_small",
        ),
        migrations.AddField(
            model_name="fooditem",
            name="image",
            field=models.FileField(
                blank=True,
                null=True,
                upload_to=foods.models.food_image_upload_path,
            ),
        ),
    ]
