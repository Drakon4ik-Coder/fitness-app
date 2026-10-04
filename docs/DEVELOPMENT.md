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
make coverage-backend   # pytest-cov, branch coverage, floor 92%
make coverage-mobile    # flutter test --coverage, floor 83%
```
CI enforces two gates per stack:
- **Overall floor**: `--cov-fail-under` (backend) / `tool/coverage.dart check --min` (mobile). The floors are a ratchet: raise them when coverage grows, never lower them to make a PR pass.
- **Diff coverage on PRs**: `diff-cover` requires 80% of the PR's changed lines to be covered. This is the guard that matters during refactors, where the overall number barely moves.

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
