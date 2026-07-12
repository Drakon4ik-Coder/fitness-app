# KAN-28 delta sync foundation: stable client identity, LWW mutation time,
# server-monotonic sync cursor, and soft-delete tombstones on MealEntry.

import uuid

import django.utils.timezone
from django.db import migrations, models


def backfill_client_uuids(apps, schema_editor):
    """Give every pre-existing entry a distinct uuid.

    AddField applies a callable default once for the whole batch, so uniqueness
    requires an explicit per-row pass. Row count is small (personal diary), so
    a simple loop is fine.
    """
    MealEntry = apps.get_model("nutrition", "MealEntry")
    for entry in MealEntry.objects.filter(client_uuid__isnull=True).iterator():
        entry.client_uuid = uuid.uuid4()
        entry.save(update_fields=["client_uuid"])


class Migration(migrations.Migration):
    dependencies = [
        ("nutrition", "0002_mealentry_meal_entry_user_time_idx"),
    ]

    operations = [
        # 1. Nullable and non-unique first, so the column can be added while
        #    existing rows have no value yet.
        migrations.AddField(
            model_name="mealentry",
            name="client_uuid",
            field=models.UUIDField(editable=False, null=True),
        ),
        migrations.RunPython(backfill_client_uuids, migrations.RunPython.noop),
        # 2. Now every row has a distinct value; tighten to the real shape.
        migrations.AlterField(
            model_name="mealentry",
            name="client_uuid",
            field=models.UUIDField(default=uuid.uuid4, editable=False, unique=True),
        ),
        # Existing rows get "migration time" for both timestamps: the first
        # delta pull always starts from a fresh cursor, so no change is missed.
        migrations.AddField(
            model_name="mealentry",
            name="updated_at",
            field=models.DateTimeField(default=django.utils.timezone.now),
        ),
        migrations.AddField(
            model_name="mealentry",
            name="synced_at",
            field=models.DateTimeField(
                auto_now=True, default=django.utils.timezone.now
            ),
            preserve_default=False,
        ),
        migrations.AddField(
            model_name="mealentry",
            name="deleted_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddIndex(
            model_name="mealentry",
            index=models.Index(
                fields=["user", "synced_at"], name="meal_entry_user_sync_idx"
            ),
        ),
    ]
