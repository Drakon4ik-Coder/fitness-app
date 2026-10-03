"""Per-file coverage floor (KAN-131).

`--cov-fail-under` only gates the total, so one weak module can hide behind
well-tested ones. Run after `pytest --cov` from apps/backend:

    python scripts/coverage_per_file.py 60

Exits 1 and lists every measured file below the floor. The percentage matches
coverage.py's own report (lines and branches combined).
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: coverage_per_file.py <min percent>")
    floor = float(sys.argv[1])
    if not 0 <= floor <= 100:
        sys.exit("min percent must be between 0 and 100")

    with tempfile.TemporaryDirectory() as tmp:
        report = Path(tmp) / "coverage.json"
        subprocess.run(
            [sys.executable, "-m", "coverage", "json", "-q", "-o", str(report)],
            check=True,
        )
        files = json.loads(report.read_text())["files"]

    below = sorted(
        (data["summary"]["percent_covered"], path)
        for path, data in files.items()
        if data["summary"]["percent_covered"] < floor
    )
    print(f"Per-file floor {floor:.2f}% across {len(files)} files.")
    for percent, path in below:
        print(f"Below the per-file floor: {path} {percent:.1f}%")
    if below:
        sys.exit(1)


if __name__ == "__main__":
    main()
