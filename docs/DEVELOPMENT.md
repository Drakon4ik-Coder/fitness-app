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

## Mutation testing (KAN-130)
Coverage says a line ran; mutation testing checks a test would notice if it
were wrong. The tools flip operators and constants (`<` to `<=`, `&&` to `||`,
`true` to `false`) one at a time and rerun the relevant tests. A mutant no test
fails on ("survived") is a gap in the assertions.

- **Targets:** backend `nutrition/views.py` and `nutrition/utils.py` (sync,
  LWW, tombstones, day bounds) with mutmut; mobile `nutrition_repository.dart`
  and `meal_suggestion.dart` with `mutation_test`.
- **When it runs:** the `Mutation tests` workflow, on PRs labelled `mutation`,
  weekly, or by hand. It is report-only: the score and every surviving mutant
  go to the job summary and the `*-mutation-report` artifacts.
- **Mobile, locally** (from `apps/mobile`, works on Windows):
  ```
  dart pub global activate mutation_test 1.8.0
  dart pub global run mutation_test -b -r mutation/rules.xml mutation/nutrition_repository.xml
  ```
  The report lands in `mutation-test-report/`. It edits the target file in
  place while it runs, so don't edit it meanwhile.
- **Backend:** CI only. mutmut needs `fork()`, so it doesn't run on Windows
  (WSL works). Config is `[tool.mutmut]` in `apps/backend/pyproject.toml`.
- **Triage a survivor** by adding a test that fails on it, or, if the mutant
  can't change behavior (an equivalent mutant), note why in the PR.

## Common Fixes
- Backend deps: `cd apps/backend && poetry install --no-interaction --no-root --sync`
- Mobile deps: `cd apps/mobile && flutter pub get`

## Optional Pre-Push Hook
```
./scripts/install-githooks.sh
```
