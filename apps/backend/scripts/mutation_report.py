"""Summarize a finished `mutmut run` for CI (KAN-130).

Writes `mutants/report.md` (score table plus the diff of every surviving
mutant) and prints the table so the workflow can append it to the job
summary. Run from apps/backend after `mutmut run`.
"""

import json
import subprocess
import sys
from pathlib import Path

MUTANTS = Path("mutants")


def mutmut(*args: str) -> str:
    return subprocess.run(
        [sys.executable, "-m", "mutmut", *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def main() -> None:
    mutmut("export-cicd-stats")
    stats = json.loads((MUTANTS / "mutmut-cicd-stats.json").read_text())
    # No-test mutants sit in code no selected test reaches; they count against
    # the score like survivors, since nothing would catch them either.
    tested = stats["killed"] + stats["survived"] + stats["no_tests"]
    score = 100 * stats["killed"] / tested if tested else 0.0

    lines = [
        "## Backend mutation score (mutmut)",
        "",
        f"**{score:.1f}%** of mutants killed ({stats['killed']}/{tested}).",
        "",
        "| killed | survived | no tests | timeout | suspicious | skipped |",
        "|---|---|---|---|---|---|",
        f"| {stats['killed']} | {stats['survived']} | {stats['no_tests']} "
        f"| {stats['timeout']} | {stats['suspicious']} | {stats['skipped']} |",
    ]
    summary = "\n".join(lines)

    survivors = [
        line.split(":")[0].strip()
        for line in mutmut("results").splitlines()
        if line.strip().endswith(("survived", "no tests"))
    ]
    diffs = [mutmut("show", name) for name in survivors]
    body = "\n\n".join(f"```diff\n{diff.strip()}\n```" for diff in diffs)
    (MUTANTS / "report.md").write_text(
        f"{summary}\n\n## Surviving mutants ({len(survivors)})\n\n{body}\n"
    )
    print(summary)


if __name__ == "__main__":
    main()
