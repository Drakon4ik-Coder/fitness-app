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

## Common Fixes
- Backend deps: `cd apps/backend && poetry install --no-interaction --no-root --sync`
- Mobile deps: `cd apps/mobile && flutter pub get`

## Optional Pre-Push Hook
```
./scripts/install-githooks.sh
```
