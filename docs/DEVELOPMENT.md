# Development

## Prereqs
- Python 3.12
- Poetry
- Flutter SDK (stable channel)

## Run Local CI
```
make check
```

## Run Per Module
```
make check-backend
make check-mobile
```

## Other Useful Targets
```
make fmt
make lint
make test
```

## Coverage (KAN-125)
```
make coverage-backend   # pytest-cov, branch coverage, floor 80%, 60% per file
make coverage-mobile    # flutter test --coverage, floor 80%, 60% per file
```
CI enforces three gates per stack. The numbers follow common industry practice: SonarQube's default quality gate requires 80% coverage on new code, and Google's guidance calls 75% commendable and 90% exemplary. Never lower a gate to make a PR pass.
- **Diff coverage on PRs (80%)**: `diff-cover` requires 80% of the PR's changed lines to be covered. This is the main gate ("clean as you code"): new and refactored code arrives tested, whatever the overall number does.
- **Overall floor (80%)**: `--cov-fail-under` (backend) / `tool/coverage.dart check --min` (mobile). A backstop; both stacks sit well above it (backend ~98%, mobile ~96%).
- **Per-file floor (60%)**: `scripts/coverage_per_file.py` (backend) / `tool/coverage.dart check --min-file` (mobile). Stops one weak file from hiding behind a high total. Fix a failing file with tests; there is no exemption list.

Mobile runs `dart run tool/coverage.dart helper` first. It generates a gitignored test that imports every `lib/` file, so an untested file counts as 0% instead of disappearing from the report. Backend excludes tests, migrations and the asgi/wsgi/local/prod settings modules (`[tool.coverage.run]` in `pyproject.toml`).

To check diff coverage locally against develop:
```
cd apps/backend && poetry run pytest --cov --cov-report=xml && cd ../..
pipx run diff-cover apps/backend/coverage.xml --compare-branch=origin/develop --fail-under=80
```

## Common Fixes
- Backend deps: `cd apps/backend && poetry install --no-interaction --no-root --sync`
- Mobile deps: `cd apps/mobile && flutter pub get`

## Optional Pre-Push Hook
```
./scripts/install-githooks.sh
```
