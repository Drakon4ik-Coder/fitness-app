# Code Health Report — July 2026

Audience: **future coding agents and contributors**. Read this before making
non-trivial changes. It records what is deliberately good (do not "fix" it),
what is genuinely wrong, and how to fix each problem without breaking the
patterns the codebase relies on.

Scope of the audit: full mobile app (`apps/mobile`, ~16.5k lines Dart), full
backend (`apps/backend`, ~6.8k lines Python excluding migrations), CI, docs,
and dependency hygiene. `flutter analyze` and `ruff check` both pass clean.

---

## Overall assessment

**This is a healthy codebase — above average for a solo project.** The
architecture is sound, the sync/offline logic is carefully designed and
unusually well commented, both stacks have real test suites (111 mobile test
cases, 133 backend), and CI guards the OpenAPI contract against drift. There
are no hardcoded secrets, no `print()` litter, no TODO/FIXME debt, and no dead
code paths of note.

The problems are concentrated, not diffuse: **two page files have grown into
"god widgets"**, **error diagnostics are systematically discarded on mobile**,
and **the written conventions have drifted from the code** (including a
missing `CLAUDE.md` that code comments still cite). Everything below is
ordered by priority.

---

## What is deliberately good — preserve these patterns

Agents pattern-match. These are the patterns to match:

1. **Layering (mobile).** Pages → `NutritionRepository` → API services +
   local stores. Pages never touch Dio or sqflite directly. Keep it that way.
2. **Constructor dependency injection, no framework.** Services are passed as
   nullable constructor params with real defaults; tests pass fakes (see
   `MainShell`). This is a *deliberate decision*: **no Riverpod, no go_router,
   no get_it** — plain `StatefulWidget` + `setState`, imperative `Navigator`.
   Do not introduce a state-management or routing framework.
3. **"Why" comments.** The code documents intent and invariants, not
   mechanics (e.g. `nutrition_repository.dart`, `nutrition/views.py` LWW and
   cursor logic). New code should meet this bar.
4. **Offline-first invariants (KAN-28).** Client-minted UUIDs as entry
   identity, outbox replay idempotent on UUID, LWW on mutation time,
   `synced_at` (server-monotonic) vs `updated_at` (client-suppliable) split,
   tombstones for deletes, cursor bootstrapped *before* day seeding. If you
   touch sync, read `nutrition_repository.dart` and
   `apps/backend/nutrition/views.py` top-to-bottom first. Do not "simplify"
   any of these — each guards a real race.
5. **Contract discipline.** `contracts/openapi.yaml` is exported from the
   backend and CI fails on drift (`backend.yml`, `make` target). Any endpoint
   change must re-export the contract.
6. **Timezone handling.** All timestamps are true UTC instants; grouping into
   days happens in the user's IANA zone on both client and server. Never
   store local times.

---

## Findings

### P1 — Two god pages dominate the mobile codebase

> **Progress (July 2026).** First extraction pass landed. `add_food_page`:
> `build()` is down from ~435 to ~200 lines (`_MealTypeSelectorTile`,
> `_SummaryBento`, `_AddedItemTile`, `_ResultsHeader`, `_EmptyResults`), and
> the `_submitItems` loop body became a named `_logOneItem` step.
> `nutrition_today_page`: `build()` is down from ~510 to ~165 lines
> (`_DateBar`, `_HeroSection`/`_KcalStat`, `_FocusCard`/`_FocusTile`,
> `_ViewFullNutrientsLink`, `_DailyLogsHeader`). `_handleBarcodeScan` was
> also split into named steps (`_setSearchTextSilently`,
> `_fetchScannedProduct`) to meet the ~80-line rule. The extracted widgets
> are private classes in their page files — move them to
> `features/nutrition/widgets/` once a second page needs one. The pages are
> still large overall (state logic remains); keep extracting when touching a
> section.

**Problem.** `features/nutrition/add_food_page.dart` is **1,676 lines** and
`nutrition_today_page.dart` is **1,365 lines**. Worst offenders inside them:

- `add_food_page.dart` `build()` — lines ~904–1340 (~435 lines)
- `add_food_page.dart` `_submitItems()` — lines ~665–872 (~207 lines,
  mixes id resolution, image upload, entry creation, error banners)
- `nutrition_today_page.dart` `build()` — lines ~555–1065 (~510 lines)

**Why it matters.** These two files are where most feature work lands, and
their size makes every edit risky: unrelated state lives in one `State`
class, and widget tests are impractical, which is why the *largest* page has
the *least* direct test coverage (see P4).

**How to fix (incremental — do not rewrite in one PR):**
- When you touch a section of `build()`, extract it into a private widget
  class in the same file first (`_FoodCard`, `_LogBar`, `_MealCard` already
  set the precedent), then move stable extracted widgets to
  `features/nutrition/widgets/`.
- Split `_submitItems()` into named steps (resolve backend ids → upload
  images → create entries → report) so failures are attributable.
- Rule of thumb for new code: **no method over ~80 lines, no widget file
  over ~500 lines.** If a page needs more, extract before adding.

### P2 — `MealType` (a domain type) lives inside a page file

> **Status: RESOLVED (July 2026).** `MealType` now lives in
> `data/food_models.dart` with explicit `wireName` (guards the API contract
> against enum renames), `label`, and `fromWire`. The icon mapping stays in
> the widget layer (`mealTypeIcon` in `amount_sheet.dart`). Raw
> `'breakfast'`-string literals in the repository, today page, and
> `kMealTypeOptions` were replaced with `MealType.values` iteration.

**Problem.** `enum MealType { breakfast, lunch, dinner, snacks }` is defined
at `add_food_page.dart:1399`. `nutrition_today_page.dart` and
`meal_suggestion.dart` import a 1,676-line page just for the enum. Meanwhile
the data layer (`nutrition_repository.dart:396-400`, API payloads) uses raw
strings `'breakfast'`… — two representations of the same concept.

**How to fix.** Move `MealType` into `features/nutrition/data/food_models.dart`
with `wireName`/`fromWire` helpers, and migrate raw-string call sites to it
(the wire format stays strings — that's the API contract). This is a
mechanical, low-risk refactor; do it before or with any meal-type feature
work.

### P3 — Error diagnostics are systematically discarded on mobile

> **Status: RESOLVED (July 2026).** The logging seam is
> `core/app_log.dart` (`logError` + assignable `appErrorLogger`);
> `mapApiErrors` in `data/api_exceptions.dart` routes all three API services
> through it (unit-tested, including the `isNetworkError` classification).
> The service-layer catch-alls in `auth_service`, `google_auth_service`,
> `off_client`, and `off_image_downloader` also log through the seam now.
> Page-level `catch (_)` blocks that consume already-typed
> `ApiException`s remain silent by design (deliberate UX). The last loose
> end closed in July 2026 (KAN-44): `main.dart` assigns `appErrorLogger` to
> a Sentry breadcrumb sink when crash reporting is enabled (non-local build
> with a DSN).

**Problem.** There are **32 `catch (_)` blocks**. Most correctly convert
failures into typed `ApiException`/`AuthException` with user-friendly
messages — the UX is fine — but the *original* exception is dropped every
time. There is no logging seam and no crash reporting in the app (Sentry is
backend-only). A field failure reads "Unable to load nutrition data." with
zero trail. Additionally, every method in the three API services hand-rolls
the same ~10-line `try / on DioException / on ApiException rethrow /
catch (_)` wrapper (e.g. `nutrition_api_service.dart` — 5 copies,
`foods_api_service.dart` — 6 copies).

**How to fix.**
1. Add one helper in `data/api_exceptions.dart`, e.g.
   `Future<T> mapApiErrors<T>(Future<T> Function() run, String friendlyMessage)`
   that centralizes the DioException→ApiException mapping (including the
   `isNetworkError` classification that the outbox depends on — preserve it
   exactly), and routes the original error to a logger hook.
2. Migrate call sites opportunistically when touching a service.
3. When the Play Store work lands (see `PLAY_STORE_ROADMAP.md`), wire the
   logger hook into the chosen crash reporter so swallowed errors become
   breadcrumbs.

**Do not** change what messages users see, and do not let auth endpoints leak
account-existence details (the generic messages there are intentional —
`auth_service.dart` comments explain the enumeration defense).

### P4 — The biggest page has no page-level tests

> **Status: RESOLVED (July 2026).** `add_food_page_test.dart` covers all the
> flows this finding named, with hand-rolled fakes (no platform channels, no
> network): quick-add from recents → submit → entry stored + outbox op queued
> via the offline repository path; tap-added-item-opens-editor (no duplicate
> staging); the empty-results nudge; search-merge across local/backend/OFF
> (barcode dedup + the OFF completeness floor); enrichment-on-tap (one
> `fetchProduct`, quick-add default lands on the fetched serving); and the
> barcode re-scan cooldown. The scan flow is injectable via the page's
> `scanBarcode` constructor param (camera needs platform channels), following
> the standard constructor-DI pattern.

**Problem.** `nutrition_today_page` has a widget test; `add_food_page` has
**none** — only its extracted helpers are tested (`category_tags`,
`live_search_controller`, `meal_suggestion`, `amount_sheet`). The
search-merge, enrichment-on-tap, barcode-cooldown, and submit flows are
untested at the page level.

**How to fix.** As P1 extractions land, add widget tests per extracted
component, plus one page-level happy-path test (search → tap → amount sheet →
log) using the existing fake-service pattern from `main_shell_test.dart` /
`in_memory_nutrition_store.dart`. Treat "extracted but untested" as
incomplete.

### P5 — Conventions doc is missing; existing docs have drifted

> **Status: RESOLVED (July 2026).** `/CLAUDE.md` now exists and
> `ARCHITECTURE.md` was rewritten against verified code (the drift was wider
> than listed below — the endpoint map, app table, and frontend tree were all
> stale). Kept for the record; the going-forward rule lives in `/CLAUDE.md`.

**Problem.**
- `live_search_controller.dart:19` cites "*CLAUDE.md: no Riverpod/go_router*"
  — but **no CLAUDE.md exists anywhere in the repo**. The project's real
  conventions live in scattered code comments and a partially stale
  `docs/ARCHITECTURE.md`.
- `ARCHITECTURE.md` claims a `ThemeModeController` ChangeNotifier for
  dark-mode toggling — it doesn't exist (the app is dark-only,
  `main.dart:24-26`).
- `ARCHITECTURE.md` claims accounts uses "Django's built-in `User`" — it's a
  custom `AbstractUser` with email login (`accounts/models.py`).

**Why it matters.** Agents trust docs. Stale docs actively cause wrong edits
(e.g. an agent "restoring" theme toggling or assuming `username` exists).

**How to fix.**
1. **Create `/CLAUDE.md`** at the repo root. Minimum contents: the
   no-framework rule (P1 item 2 above), the layering rule, the sync
   invariants pointer, the contract-export requirement, commit style
   (1-line messages, feature branches, no auto-PRs), and "update
   ARCHITECTURE.md in the same PR when structure changes".
2. Fix the two stale claims in `ARCHITECTURE.md` now.
3. Convention going forward: any PR that changes structure or conventions
   updates the doc in the same PR.

### P6 — Unused dependencies mislead readers

> **Status: RESOLVED (July 2026).** Both packages removed from
> `pubspec.yaml`; full test suite (165 cases) and analyzer pass. The
> no-framework rule lives in `/CLAUDE.md`.

**Problem.** `hooks_riverpod` and `go_router` are declared in
`apps/mobile/pubspec.yaml` but the project deliberately uses neither
(ARCHITECTURE.md even documents them as unused). Declared-but-banned
dependencies are a trap: an agent seeing `hooks_riverpod` in pubspec will
reasonably start writing providers.

**How to fix.** Remove both from `pubspec.yaml` (one-line each; `flutter pub
get`, run tests). If they're kept for a planned migration, say so in
CLAUDE.md instead — but removal is the recommendation.

### P7 — Small duplications and token gaps

> **Status: RESOLVED (July 2026).** `pushFoodDetailPage` in
> `food_detail_page.dart` now owns the push-and-collect-result flow (both
> pages delegate); the hairline literal became
> `LuminaHealthColors.hairline` and all 8 uses migrated.

- ~~`_openFoodDetail` duplicated~~ — extracted to `pushFoodDetailPage`.
- ~~Hairline-border literal repeated~~ — now `LuminaHealthColors.hairline`.
- ~~Inset-edge literal (`Colors.white @ 0.1`) hardcoded~~ — now
  `LuminaHealthColors.innerHighlight` (KAN-41). The only raw white/black
  left in nutrition feature code is the image stack in `add_food_page.dart`
  (legibility gradient, enrich scrim, name text over photos) — those are
  theme-independent by design.

### P8 — Lint configuration is looser than the codebase deserves

> **Status: RESOLVED (July 2026).** Mobile: `unawaited_futures`,
> `avoid_dynamic_calls`, `directives_ordering`, `prefer_final_locals` enabled
> (all violations fixed — deliberate fire-and-forget calls are now explicit
> `unawaited(...)`); repo reformatted with Dart 3.9 tall style in a standalone
> commit; `dart format --set-exit-if-changed` added to CI and
> `make check-mobile`. Backend: ruff `select = ["E","F","I","B","DJ"]` with
> DJ001 ignored (shipped schema) and migrations exempt from E501; standalone
> isort removed (ruff `I` replaces it).

**Problem.** `analysis_options.yaml` is the stock `flutter_lints` template
with zero customization; CI runs `dart analyze` and `flutter test` but not
`dart format --set-exit-if-changed`. Backend `ruff` runs with default rule
selection only. The code is currently cleaner than the tooling requires —
which means regressions won't be caught.

**How to fix.**
- Mobile: enable at least `unawaited_futures`, `avoid_dynamic_calls`,
  `directives_ordering`, `prefer_final_locals`; add a format check step to
  `mobile.yml`. Expect a small one-time cleanup.
- Backend: extend ruff selection (e.g. `select = ["E", "F", "I", "B", "DJ"]`)
  and let `I` replace standalone isort.

### Notes (no action required, just awareness)

- **Dead UI code removed (July 2026, KAN-63):** `features/
  barcode_lookup_page.dart` (superseded by the scanner flow inside
  `add_food_page`; only its own test referenced it) and three unused pulse
  components (`neon_pill_button.dart`, `glass_meal_card.dart`,
  `macro_ring.dart`). If a design calls for them again, recover from git
  history rather than keeping them compiled in.
- **Two separate SQLite databases** exist by design: `food_local_db.dart`
  (food catalog cache, schema v7) and `nutrition_local_store.dart` (entries +
  outbox + day payloads, schema v2). They have independent migration
  histories. Don't merge them casually, and don't add a third store without
  documenting why. Since KAN-64 both are namespaced per server user id
  (`_u<id>` suffix, `local_db_paths.dart`), so logout keeps the files — an
  unsynced outbox survives re-login and can never replay into another
  account. Do not reintroduce a wipe-on-logout; only account deletion (KAN-42)
  calls `clear()`.
- ~~`assert isinstance(request.user, User)` in `nutrition/views.py` exists
  for mypy narrowing~~ — replaced with `typing.cast` (July 2026), so nothing
  changes under `python -O`. Keep using `cast` (not `assert`) for
  `request.user` narrowing in new views.
- `NutritionEntry.id == 0` is the sentinel for "offline entry not yet
  assigned a server id" (`nutrition_repository.dart:436`,
  `food_models` mapping). It's documented at the definition; don't treat 0 as
  a real id anywhere.
- OFF (Open Food Facts) never provides per-piece nutrition and
  search-a-licious omits serving data — the lazy-enrich-on-tap flow in
  `add_food_page` exists for this reason. Don't "optimize" it into eager
  enrichment; it would hammer the OFF API (rate limiter in
  `off_rate_limiter.dart`).
- The nutrient catalog is intentionally **mirrored** in
  `apps/backend/nutrients/catalog.py` and
  `apps/mobile/lib/features/nutrition/data/nutrient_catalog.dart`. There is
  a drift check (`apps/backend/tests/test_nutrient_catalog_drift.py`, added
  July 2026) that fails CI when they diverge — still change both in the same
  PR.

---

## Suggested order of work

| # | Action | Effort | Payoff |
|---|--------|--------|--------|
| 1 | ~~Create `/CLAUDE.md`; fix stale ARCHITECTURE.md claims (P5)~~ **done** | ~1 h | Stops agents inheriting wrong assumptions |
| 2 | ~~Remove `hooks_riverpod` + `go_router` (P6)~~ **done** | 10 min | Removes a framework trap |
| 3 | ~~Move `MealType` to `food_models.dart` (P2)~~ **done** | ~1 h | Untangles page imports |
| 4 | ~~Central `mapApiErrors` helper + logging seam (P3)~~ **done** (incl. Sentry wiring in main.dart, KAN-44) | ~2 h | Field debuggability; kills ~30 boilerplate blocks over time |
| 5 | Incremental extraction of the two god pages + tests (P1/P4) | P4 **done**; P1 first pass done (both `build()`s split up, `_logOneItem`, barcode-scan steps) — keep extracting opportunistically | Long-term velocity |

Everything in this report is resolved (the last item, `appErrorLogger` →
Sentry in `main.dart`, landed with KAN-44 in July 2026); P1's size rule
(~80-line methods, ~500-line widget files) applies to new code and to
sections as they are touched.
| 6 | ~~Lint tightening + format CI step (P8)~~ **done** | ~1 h | Locks in current quality |
| 7 | ~~Tokens + small dedup (P7); catalog drift check (Notes)~~ **done** | opportunistic | Consistency |

Items 1–3 are safe, mechanical, and can be done in a single short session.
