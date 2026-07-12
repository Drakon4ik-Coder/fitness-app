from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("preferences", "0002_userpreferences_nutrient_goals"),
    ]

    operations = [
        migrations.AddField(
            model_name="userpreferences",
            name="focus_nutrients",
            field=models.JSONField(blank=True, default=list),
        ),
    ]
