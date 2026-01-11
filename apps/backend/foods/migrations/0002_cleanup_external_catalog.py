from django.db import migrations


class Migration(migrations.Migration):
    dependencies = [
        ("foods", "0001_initial"),
    ]

    operations = [
        migrations.RunSQL(
            sql="DROP TABLE IF EXISTS external_catalog_externalfooditemcache",
            reverse_sql=migrations.RunSQL.noop,
        )
    ]
