from django.db import migrations

# Food typeahead filters `name__icontains | brands__icontains`, which Django
# compiles to `UPPER(col::text) LIKE UPPER('%q%')`. A leading-wildcard LIKE can't
# use a btree, so without these every search scanned the whole catalog
# (KAN-121). GIN trigram indexes on exactly that expression can serve it.
#
# Postgres-only and invisible to the model state on purpose: tests run on
# SQLite (no pg_trgm), and Django's index API can't express a vendor-gated
# expression index. CONCURRENTLY keeps the catalog writable while the index
# builds on deploy, which is why this migration is non-atomic.
_INDEXES = (
    ("foods_name_upper_trgm", "name"),
    ("foods_brands_upper_trgm", "brands"),
)


def _index_validity(schema_editor, index_name):
    """True/False for an existing index's pg_index.indisvalid, None if absent."""
    with schema_editor.connection.cursor() as cursor:
        cursor.execute(
            "SELECT i.indisvalid FROM pg_index i "
            "JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = %s",
            [index_name],
        )
        row = cursor.fetchone()
    return None if row is None else bool(row[0])


def _create_indexes(apps, schema_editor):
    if schema_editor.connection.vendor != "postgresql":
        return
    schema_editor.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    for index_name, column in _INDEXES:
        # A failed CONCURRENTLY build leaves an INVALID index behind. On the
        # retry deploy, IF NOT EXISTS would see the name and skip it, and the
        # migration would be recorded with a dead index, so drop the leftover
        # first.
        if _index_validity(schema_editor, index_name) is False:
            schema_editor.execute(f"DROP INDEX CONCURRENTLY IF EXISTS {index_name}")
        schema_editor.execute(
            f"CREATE INDEX CONCURRENTLY IF NOT EXISTS {index_name} "
            f'ON foods_fooditem USING gin (UPPER("{column}"::text) gin_trgm_ops)'
        )
        if _index_validity(schema_editor, index_name) is not True:
            raise RuntimeError(f"Index {index_name} is missing or INVALID.")


def _drop_indexes(apps, schema_editor):
    if schema_editor.connection.vendor != "postgresql":
        return
    # The extension stays: other objects may depend on it by then.
    for index_name, _column in _INDEXES:
        schema_editor.execute(f"DROP INDEX CONCURRENTLY IF EXISTS {index_name}")


class Migration(migrations.Migration):
    atomic = False

    dependencies = [
        ("foods", "0010_alter_fooditem_source"),
    ]

    operations = [
        migrations.RunPython(_create_indexes, _drop_indexes),
    ]
