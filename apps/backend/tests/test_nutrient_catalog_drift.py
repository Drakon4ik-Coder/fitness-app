"""Guards the mirrored nutrient catalog (CLAUDE.md rule 7).

`nutrients/catalog.py` and the mobile app's `nutrient_catalog.dart` must
describe the same nutrients: same keys, OFF field mappings, canonical units,
grouping, and completeness tracking. This test parses the Dart source with
regexes — crude, but it only needs to trip when one side changes without the
other. Display labels and daily targets are client-side concerns and are not
compared.
"""

import re
from pathlib import Path

from nutrients.catalog import NUTRIENT_CATALOG

_DART_CATALOG = (
    Path(__file__).parents[3]
    / "apps"
    / "mobile"
    / "lib"
    / "features"
    / "nutrition"
    / "data"
    / "nutrient_catalog.dart"
)


def _parse_dart_catalog() -> list[tuple[str, str, str, str, bool]]:
    source = _DART_CATALOG.read_text(encoding="utf-8")
    match = re.search(
        r"const List<NutrientSpec> kNutrientCatalog = \[(.*?)^\];",
        source,
        re.DOTALL | re.MULTILINE,
    )
    assert match, "kNutrientCatalog list not found in nutrient_catalog.dart"
    entries = []
    for chunk in match.group(1).split("NutrientSpec(")[1:]:
        key = re.search(r"key: '([^']+)'", chunk)
        off_key = re.search(r"offKey: '([^']+)'", chunk)
        unit = re.search(r"unit: '([^']+)'", chunk)
        group = re.search(r"group: NutrientGroup\.(\w+)", chunk)
        assert key and off_key and unit and group, f"unparseable entry: {chunk[:80]}"
        entries.append(
            (
                key.group(1),
                off_key.group(1),
                unit.group(1),
                group.group(1),
                "completenessTracked: true" in chunk,
            )
        )
    return entries


def test_dart_catalog_file_exists():
    assert _DART_CATALOG.is_file(), (
        f"Dart catalog not found at {_DART_CATALOG} — if it moved, update this "
        "test; the mirror invariant still applies."
    )


def test_catalogs_match():
    python_side = [
        (s.key, s.off_key, s.unit, s.group, s.completeness_tracked)
        for s in NUTRIENT_CATALOG
    ]
    dart_side = _parse_dart_catalog()
    assert python_side == dart_side, (
        "nutrients/catalog.py and nutrient_catalog.dart have drifted apart — "
        "they must change together in the same PR (CLAUDE.md rule 7)."
    )
