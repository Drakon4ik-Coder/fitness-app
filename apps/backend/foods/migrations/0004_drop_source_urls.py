from django.db import migrations


class Migration(migrations.Migration):
    dependencies = [
        ("foods", "0003_fooditem_images_and_hash"),
    ]

    operations = [
        migrations.RemoveField(
            model_name="fooditem",
            name="image_large_source_url",
        ),
        migrations.RemoveField(
            model_name="fooditem",
            name="image_small_source_url",
        ),
    ]
