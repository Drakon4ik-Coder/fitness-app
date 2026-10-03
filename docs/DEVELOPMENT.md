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

## Screenshot (golden) tests (KAN-129)
`apps/mobile/test/goldens/` renders the main screens (today, add food, the
amount and meal sheets, login) at phone size with the real bundled fonts and
compares them against the PNGs in `test/goldens/images/`. They run as part of
`flutter test`.

- **Where they're authoritative:** Linux, which is what CI runs. Up to 0.5% of
  pixels may differ (anti-aliasing noise); a moved, resized or recolored widget
  changes far more and fails. Other platforms render text slightly differently
  (Windows is ~1.3% off), so local runs there allow 5%: still enough to catch a
  broken layout, while CI catches the subtle changes.
- **When one fails in CI:** download the `golden-failures` artifact from the run.
  It holds the expected, actual and diff images.
- **After an intended UI change:** add the `update-goldens` label to the PR. The
  `Update goldens` workflow re-renders them on Linux and uploads a `goldens`
  artifact; copy its PNGs into `apps/mobile/test/goldens/images/` and commit.
  On Linux you can also run `flutter test --update-goldens test/goldens`.
- **New screen:** add a `testWidgets` with `matchesGoldenFile('images/<name>.png')`
  to `screens_golden_test.dart`, using fake services and fixed data so the
  render is deterministic.

## Common Fixes
- Backend deps: `cd apps/backend && poetry install --no-interaction --no-root --sync`
- Mobile deps: `cd apps/mobile && flutter pub get`

## Optional Pre-Push Hook
```
./scripts/install-githooks.sh
```
