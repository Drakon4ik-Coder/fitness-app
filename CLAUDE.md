# CLAUDE.md — project conventions

Symbio: a fitness/nutrition tracking app. Monorepo — `apps/backend` (Django
REST Framework + Postgres) and `apps/mobile` (Flutter). Read
`docs/ARCHITECTURE.md` for the map, `docs/CODE_HEALTH.md` for known debt and
refactor guidance.

## Commands

Run from the repo root:

- `make check` — full local CI (both stacks: format check, lint, typecheck, tests, contract drift)
- `make check-backend` / `make check-mobile` — one stack
- `make fmt` / `make lint` / `make test` — narrower slices
- `make backend-contract` — re-export `contracts/openapi.yaml` and fail on drift

Backend deps: `cd apps/backend && poetry install --no-interaction --no-root --sync`.
Mobile deps: `cd apps/mobile && flutter pub get`.

## Hard rules (deliberate decisions — do not "improve" these)

1. **No state-management or routing frameworks.** Plain `StatefulWidget` +
   `setState`; imperative `Navigator`. No Riverpod, no go_router, no get_it,
   no bloc. Do not add such packages to `pubspec.yaml`.
2. **Constructor DI.** Services are nullable constructor params with real
   defaults; tests pass fakes (see `MainShell`, `main_shell_test.dart`).
3. **Layering (mobile).** Pages → `NutritionRepository` → API services +
   local stores. Pages never touch Dio or sqflite directly.
4. **Hand-written JSON models.** No `json_serializable`/`freezed`/codegen.
5. **Timestamps are true UTC instants everywhere.** Grouping into calendar
   days happens in the user's IANA timezone (client and server both). Never
   store local wall-clock times.
6. **API contract discipline.** Any backend endpoint/serializer change must
   re-export `contracts/openapi.yaml` (`make backend-contract`) in the same
   commit — CI fails on drift.
7. **Mirrored nutrient catalog.** `apps/backend/nutrients/catalog.py` and
   `apps/mobile/lib/features/nutrition/data/nutrient_catalog.dart` must change
   together in the same PR. `tests/test_nutrient_catalog_drift.py` (backend)
   fails when they diverge.
8. **Offline sync invariants (KAN-28).** Before touching sync, read
   `nutrition_repository.dart` and `apps/backend/nutrition/views.py` in full.
   Non-negotiables: client-minted UUID is the entry's identity for life;
   outbox replay is idempotent on that UUID; conflicts resolve last-write-wins
   on mutation time; `synced_at` (server-monotonic, cursor basis) is distinct
   from `updated_at` (client-suppliable, LWW basis); deletes are tombstones;
   the sync cursor is bootstrapped *before* day seeding. Each of these guards
   a real race — do not simplify.
9. **Error messages.** Auth endpoints stay deliberately vague (account-
   enumeration defense). `ApiException.isNetworkError` classifies
   offline-vs-server-verdict and the outbox replay depends on it — preserve
   the classification exactly when refactoring error handling.
10. **Theming.** Dark-only by design (`LuminaHealthTheme.dark()` fills the
    light slot). Use `ui_system/` tokens and theme colors; do not add new
    hardcoded `Color(...)`/`Colors.*` literals in feature code.
11. **OFF (Open Food Facts) is rate-limited.** Enrichment is lazy
    (on-tap) on purpose; never make it eager. Respect
    `off_rate_limiter.dart`.

## Working style

- **Commits:** one-line messages, on feature branches (`features/...`). Do
  not open PRs unless asked.
- **Docs stay true:** a PR that changes structure, endpoints, or conventions
  updates `docs/ARCHITECTURE.md` (and this file if a rule changes) in the
  same PR.
- **Size discipline:** no new method over ~80 lines; extract private widget
  classes rather than growing `build()`. The two oversized pages
  (`add_food_page.dart`, `nutrition_today_page.dart`) are being shrunk
  incrementally — when you touch a section, extract it (see
  `docs/CODE_HEALTH.md` P1).
- **Comments** explain *why* (invariants, races, product constraints), never
  *what* the next line does. Match the density already in
  `nutrition_repository.dart`.
- **Tests:** backend `pytest` (sqlite in tests), mobile `flutter test` with
  fake services — no network in tests. New extracted widgets get widget
  tests; new endpoints get API tests.

## Gotchas

- `NutritionEntry.id == 0` means "created offline, no server id yet" — never
  treat 0 as a real server id.
- Two separate SQLite DBs on device: `food_local_db.dart` (catalog cache,
  schema v7) and `nutrition_local_store.dart` (entries/outbox/day payloads,
  schema v2). Independent migration histories; neither is per-user —
  `clear()` on logout is mandatory and already wired.
- Meat foods with cooked-basis labels: grams are stored cooked-equivalent;
  raw entry applies a 0.75 yield factor (see amount sheet logic).
- OFF never provides per-piece nutrition and its search omits serving data —
  that's why piece parsing + lazy enrich exist.
