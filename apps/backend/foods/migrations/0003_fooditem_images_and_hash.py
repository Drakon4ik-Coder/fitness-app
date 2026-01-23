from django.db import migrations, models
import foods.models


class Migration(migrations.Migration):
    dependencies = [
        ("foods", "0002_cleanup_external_catalog"),
    ]

    operations = [
        migrations.AddField(
            model_name="fooditem",
            name="content_hash",
            field=models.CharField(blank=True, max_length=128, null=True),
        ),
        migrations.AddField(
            model_name="fooditem",
            name="image_signature",
            field=models.CharField(blank=True, max_length=128, null=True),
        ),
        migrations.AddField(
            model_name="fooditem",
            name="image_large",
            field=models.FileField(
                blank=True,
                null=True,
                upload_to=foods.models.food_image_upload_path,
            ),
        ),
        migrations.AddField(
            model_name="fooditem",
            name="image_small",
            field=models.FileField(
                blank=True,
                null=True,
                upload_to=foods.models.food_image_upload_path,
            ),
        ),
        migrations.AddField(
            model_name="fooditem",
            name="image_large_source_url",
            field=models.URLField(blank=True, default=""),
        ),
        migrations.AddField(
            model_name="fooditem",
            name="image_small_source_url",
            field=models.URLField(blank=True, default=""),
        ),
        migrations.AddField(
            model_name="fooditem",
            name="image_downloaded_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="fooditem",
            name="image_status",
            field=models.CharField(
                choices=[("ok", "OK"), ("failed", "Failed"), ("none", "None")],
                default="none",
                max_length=16,
            ),
        ),
    ]
