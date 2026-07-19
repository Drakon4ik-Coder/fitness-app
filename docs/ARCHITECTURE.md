# Architecture

> Keep this document true: any PR that changes structure, endpoints, or
> conventions must update it in the same PR (see `/CLAUDE.md`).

## Repo layout

Monorepo:

```
fitness-app/
├── apps/
│   ├── backend/        # Django API (Dockerfile lives here)
│   └── mobile/         # Flutter app
├── contracts/
│   └── openapi.yaml    # Exported API schema; CI fails on drift
├── docs/               # This file, DEVELOPMENT, RELEASE, ROADMAP, CODE_HEALTH, OPERATIONS
├── scripts/            # Dev tooling (githooks, ciqual generator, dev-phone)
├── ops/
│   └── db-backup/      # Nightly pg_dump→rclone sidecar for prod (docs/OPERATIONS.md)
├── .github/workflows/  # backend.yml, mobile.yml, mobile-release.yml, deploy-server.yml
├── Makefile            # Local CI entry points (make check)
├── docker-compose.yml
├── docker-compose.prod.yml
└── render.yaml         # Render.com deploy config
```

---

## Quick facts

| Concern | Answer |
|---|---|
| API style | **Django REST Framework** (`APIView` / `generics.*`; no plain Django views except `/health/` and token-link endpoints) |
| Auth | **SimpleJWT** — 5-min access token, 30-day refresh token; Google Sign-In exchange; email verification gate on login |
| User model | **Custom `accounts.User`** (`AbstractUser`, email as login identity, `timezone` field). Plus `EmailVerificationToken`, `PasswordResetToken`. |
| Database | **Postgres** via `DATABASE_URL` env var (sqlite in tests) |
| API docs | Auto-generated via `drf-spectacular`; served at `/api/docs/` (Swagger UI) |
| Flutter state mgmt | **Plain `StatefulWidget` + `setState`** — no framework, by decision (see `/CLAUDE.md`) |
| Flutter theming | **Dark-only**: `LuminaHealthTheme.dark()` fills the light slot in `main.dart`; there is no theme toggling. |
| Flutter HTTP client | **Dio** (`^5.9.0`) |
| Flutter routing | **Imperative `Navigator`**. Top-level auth routing is the `AuthGate` switch in `main.dart`. |
| Flutter JSON models | **Hand-written** — no `json_serializable` or `freezed` |
| Offline story | Entry-level local cache + outbox + delta sync (KAN-28). See `nutrition_repository.dart` and `nutrition/views.py` docstrings. |

---

## Backend — Django apps

Project package: `apps/backend/config/`
Settings are layered: `config/settings/{base,local,prod,test}.py`
Root URLconf: `config/urls.py`

### Apps

| App | Models | Purpose |
|---|---|---|
| `accounts/` | `User` (custom, email login), `EmailVerificationToken`, `PasswordResetToken` | Registration, login (password + Google), email verification, password reset, `/me` |
| `preferences/` | `UserPreferences` | Per-user goals/units/settings (GET/PUT) |
| `foods/` | `FoodItem`, `FoodEditProposal` | Food catalog (OFF-sourced + owner-scoped custom foods), fork-on-edit overrides, edit-proposal promotion |
| `nutrition/` | `MealEntry` | Meal logging, day totals + nutrient breakdown, delta sync feed, learned meal times |
| `nutrients/` | `NutrientDefinition` | Nutrient reference data; `catalog.py` is the canonical nutrient catalog (mirrored in Dart — change both together) |

### Views

`accounts/views.py`
- `RegisterView` (generics.CreateAPIView)
- `EmailVerifiedTokenObtainPairView` — login, gated on verified email
- `GoogleLoginView` — Google ID-token exchange
- `MeView` — GET profile (incl. accepted/current policy versions) / PATCH (e.g. timezone)
- `ResendVerificationView`, `PasswordResetRequestView`
- `verify_email`, `reset_password` — emailed-link endpoints (plain views)
- `request_account_deletion`, `confirm_account_deletion` — logged-out web deletion flow (Play requirement, KAN-42)
- `privacy_policy` — static privacy-policy page (Play requirement, KAN-43)
- `terms_of_service` — static Terms of Service page (KAN-103)
- `AcceptPolicyView` — post-hoc consent recording for Google sign-ins / policy bumps (KAN-103); `accounts/permissions.py` holds the `PolicyConsentAccepted` gate applied to the nutrition/foods/preferences views

`foods/views.py`
- `FoodTypeaheadView` — name-based search
- `FoodIngestView` — import a food from OpenFoodFacts
- `CustomFoodView`, `CustomFoodDetailView` — owner-scoped custom foods (upsert by client UUID)
- `FoodCheckView` — barcode/content-hash freshness check
- `FoodImageUploadView` — multipart image upload for a food item

`nutrition/views.py`
- `MealEntryCreateView` — log a meal (idempotent on `client_uuid`; a re-create carrying a `client_updated_at` newer than the entry's tombstone resurrects it in place — the undo path for swipe-to-delete, KAN-39)
- `MealEntryDetailView` — PATCH/DELETE by pk or client UUID (LWW conflict rules)
- `MealEntrySyncView` — delta feed with opaque `synced_at|id` cursor
- `NutritionDayView` — totals + per-nutrient breakdown for a date
- `MealTimesView` — learned typical meal times (cached per user+tz)

`preferences/views.py`
- `PreferencesView` — GET/PUT the user's preferences

### URL mounts (`config/urls.py`)

| Prefix | App |
|---|---|
| `/api/v1/auth/` | `accounts.urls` |
| `/api/v1/foods/` | `foods.urls` |
| `/api/v1/nutrition/` | `nutrition.urls` |
| `/api/v1/preferences/` | `preferences.urls` |
| `/api/schema/`, `/api/docs/` | drf-spectacular schema + Swagger UI |
| `/admin/` | Django admin |
| `/health/` | JSON healthcheck: backend version + `min_supported_build` for the forced-update gate (KAN-100) |
| `/.well-known/assetlinks.json` | Android app-link / shared-credential affiliation |
| `/delete-account` | Logged-out web account-deletion request + emailed confirm link |
| `/privacy` | Hosted privacy policy (linked from Settings → About and the store listing) |
| `/terms` | Hosted Terms of Service (linked from signup, the consent screen and Settings → About, KAN-103) |

---

## Frontend — Flutter feature folders

All source lives under `apps/mobile/lib/`.

```
lib/
├── main.dart                    # FitnessApp + AuthGate (login ↔ MainShell); Sentry init; reports device tz
├── core/
│   ├── auth_service.dart        # login / register / google / reset / timezone, JWT exchange
│   ├── auth_interceptor.dart    # Dio interceptor: attaches token, deduplicated 401 refresh
│   ├── auth_storage.dart        # flutter_secure_storage wrapper (access + refresh keys)
│   ├── google_auth_service.dart # google_sign_in wrapper
│   ├── environment.dart         # apiBaseUrl etc. from --dart-define
│   ├── version_check_service.dart # /health/ min_supported_build probe (KAN-100)
│   ├── update_gate.dart         # startup forced-update gate + blocking dialog (fail-open)
│   ├── legal_links.dart         # canonical /privacy + /terms URLs
│   └── policy_consent_gate.dart # blocking policy-consent screen for signed-in users (fail-open, KAN-103)
├── features/
│   ├── login_page.dart / register_page.dart / forgot_password_page.dart
│   ├── main_shell.dart          # Signed-in bottom-nav shell; owns shared UserPreferences
│   └── nutrition/
│       ├── nutrition_today_page.dart    # Day view (track tab)
│       ├── add_food_page.dart           # Search/scan/log flow (largest page)
│       ├── food_detail_page.dart        # Read-first food detail with edit entry points
│       ├── custom_food_page.dart        # Create/edit custom foods
│       ├── nutrition_detail_page.dart   # Full nutrient breakdown for a day
│       ├── nutrition_scan_page.dart     # Barcode camera
│       ├── account_page.dart            # Account tab + settings hub
│       ├── live_search_controller.dart  # Debounce + cancel for the search flow
│       ├── meal_suggestion.dart         # Meal-type guess from learned meal times
│       ├── settings/                    # Profile / Units / Goals / Focus-nutrients / Warnings / About sub-pages
│       ├── widgets/                     # amount_sheet, meal_detail_sheet, nutrient views
│       └── data/
│           ├── nutrition_repository.dart    # Offline-first read/write + outbox + delta sync
│           ├── nutrition_local_store.dart   # sqflite: entries, outbox, day payloads, cursor (v2)
│           ├── nutrition_api_service.dart   # /api/v1/nutrition/* calls
│           ├── foods_api_service.dart       # /api/v1/foods/* calls
│           ├── preferences_api_service.dart # /api/v1/preferences calls
│           ├── food_models.dart             # FoodItem + JSON parsing helpers
│           ├── food_local_db.dart           # sqflite food catalog cache (v8)
│           ├── food_sync.dart               # ensure-backend-id / custom-food sync helpers
│           ├── nutrient_catalog.dart        # Mirrors backend nutrients/catalog.py
│           ├── ciqual_raw_refs.dart         # Generated cooked-basis reference data
│           ├── user_preferences.dart
│           ├── off_client.dart              # OpenFoodFacts API client
│           ├── off_mapper.dart              # OFF response → FoodItem
│           ├── off_image_downloader.dart / off_rate_limiter.dart
│           ├── fatsecret_client.dart        # Backend FatSecret proxy client (KAN-67)
│           ├── fatsecret_mapper.dart        # FatSecret response → FoodItem
│           └── api_exceptions.dart
├── ui_components/               # Shared widgets (AppScaffold, fields, banners, pulse/*)
└── ui_system/                   # lumina_health_theme.dart + tokens.dart (spacing/radius)
```

Only `features/nutrition/` has a `data/` layer; other features are single-file pages.

---

## How the two sides talk

### Transport

The Flutter app talks to the Django backend over HTTPS using Dio.
Base URL is chosen at build time via `--dart-define=APP_ENV`
(`API_BASE_URL` overrides directly). Each environment is also a separate
Android **product flavor** (`android/app/build.gradle.kts`) with its own
application id, so all three install side by side on one device instead of
replacing each other:

| ENV / flavor | URL | Application id | Launcher label |
|---|---|---|---|
| `local` | `http://localhost:8000` | `uk.drakon4ik.symbio.dev` | Symbio Dev |
| `staging` | Render staging URL | `uk.drakon4ik.symbio.staging` | Symbio Staging |
| `prod` | `https://symbio.drakon4ik.uk` | `uk.drakon4ik.symbio` | Symbio |

Every Android build/run must pass `--flavor` (bare `flutter run` fails once
flavors exist), and the flavor must match `APP_ENV` — use `make dev-local`,
`make dev-phone`, or the CI workflows, which pair them correctly. Google
Sign-In is registered per (application id, signing SHA-1): each flavor's id
needs its own Android OAuth client in the Google Cloud project. Prod ships
via `mobile-release.yml` (GitHub Releases APK + Play AAB); staging ships via
`mobile-staging.yml` (Firebase App Distribution — setup steps in that file's
header comment).

Each API service creates its own `Dio` instance and calls
`authInterceptor?.attachTo(_dio)` to wire up auth.

### Crash reporting (Sentry)

One Sentry org, two projects (backend, mobile); staging and prod are
separated inside each project by the `environment` tag, and `local` never
reports (a DSN present locally is ignored on both sides — localhost errors
are noise).

- Mobile: `main.dart` initializes `sentry_flutter` only when
  `--dart-define=SENTRY_DSN` is set and `APP_ENV != local`; the environment
  tag is `APP_ENV`. It also assigns `appErrorLogger` (`core/app_log.dart`) so
  swallowed service-layer errors become breadcrumbs on the next real crash.
  Local runs and tests keep the logger null.
- Backend: `config/settings/base.py` initializes `sentry-sdk` only when
  `SENTRY_DSN` is set and `SENTRY_ENVIRONMENT != local` (the default).
  Render (staging) sets `SENTRY_ENVIRONMENT=staging` in `render.yaml`; the
  prod server sets `SENTRY_ENVIRONMENT=prod` in its `.env`.

### JWT lifecycle

1. **Login** — `AuthService.login()` posts to `/api/v1/auth/token` and stores the returned `access` + `refresh` tokens via `AuthStorage` (`flutter_secure_storage`). Google Sign-In exchanges an ID token at `/api/v1/auth/google` for the same pair.
2. **Every request** — `AuthInterceptor.onRequest` reads the access token and attaches `Authorization: Bearer <token>`.
3. **On 401** — the interceptor calls `/api/v1/auth/refresh` (deduplicated — concurrent 401s share one refresh future), stores the new token, updates all attached `Dio` instances, then replays the original request transparently.
4. **Refresh failure** — fires `onSessionExpired`, which calls `_AuthGateState._handleLogout` in `main.dart`, returning the user to `LoginPage`. Logout clears only the stored tokens; the local DBs are kept (they are namespaced per server user id since KAN-64, so an unsynced outbox survives re-login and can never replay into another account).
5. **Backend side** — `EmailVerifiedTokenObtainPairView` / SimpleJWT's `TokenRefreshView`, mounted in `accounts/urls.py`. Token lifetimes in `config/settings/base.py`.

### Endpoint map

| Mobile call | Backend view |
|---|---|
| `POST /api/v1/auth/register` | `RegisterView` |
| `POST /api/v1/auth/token` | `EmailVerifiedTokenObtainPairView` |
| `POST /api/v1/auth/refresh` | `TokenRefreshView` |
| `POST /api/v1/auth/google` | `GoogleLoginView` |
| `GET/PATCH /api/v1/auth/me` | `MeView` (PATCH: timezone etc.) |
| `DELETE /api/v1/auth/me` | `MeView` (account deletion; re-auth via password or fresh Google ID token, KAN-42) |
| `POST /api/v1/auth/resend-verification` | `ResendVerificationView` |
| `POST /api/v1/auth/password-reset` | `PasswordResetRequestView` |
| `POST /api/v1/auth/change-password` | `PasswordChangeView` (logged-in change; current password as re-auth, KAN-50) |
| `POST /api/v1/auth/accept-policy` | `AcceptPolicyView` (records consent at the current `POLICY_VERSION`, KAN-103) |
| `GET /api/v1/foods/typeahead` | `FoodTypeaheadView` |
| `POST /api/v1/foods/ingest` | `FoodIngestView` |
| `POST /api/v1/foods/custom`, `PATCH/DELETE /api/v1/foods/custom/<id>` | `CustomFoodView` / `CustomFoodDetailView` |
| `GET /api/v1/foods/check` | `FoodCheckView` |
| `POST /api/v1/foods/<id>/images` | `FoodImageUploadView` |
| `GET /api/v1/foods/fatsecret/search`, `GET /api/v1/foods/fatsecret/food/<id>` | `FatSecretSearchView` / `FatSecretFoodView` (verbatim FatSecret passthrough, KAN-67) |
| `POST /api/v1/nutrition/entries` | `MealEntryCreateView` |
| `PATCH/DELETE /api/v1/nutrition/entries/<pk>` and `.../by-uuid/<uuid>` | `MealEntryDetailView` |
| `GET /api/v1/nutrition/entries/sync` | `MealEntrySyncView` |
| `GET /api/v1/nutrition/day` | `NutritionDayView` |
| `GET /api/v1/nutrition/meal-times` | `MealTimesView` |
| `GET/PUT /api/v1/preferences/` | `PreferencesView` |

The exported contract in `contracts/openapi.yaml` is the source of truth;
CI regenerates it and fails on drift.

### OpenFoodFacts — called from both sides

The mobile app queries OFF directly via `off_client.dart` (barcode lookup,
food search; rate-limited via `off_rate_limiter.dart`, enrichment is lazy
on-tap by design) and uploads the resulting image to the backend via
`foods_api_service.dart`. The backend uses the same source
(`SOURCE_OPEN_FOOD_FACTS` in `foods/models.py`) when ingesting or checking
foods server-side.

Uploaded images live on the `media-data` volume and are served by Django
itself at `/media/` (`config/urls.py`, not DEBUG-gated — WhiteNoise only
covers staticfiles). Rows whose media file has gone missing (pre-volume
writes, volume loss) are healed by
`manage.py repair_food_images [--dry-run]`: it resets the image bookkeeping
so serializers fall back to the original source `image_url` and clients can
re-upload.

### FatSecret — proxied through the backend (KAN-67)

OFF is barcode-driven and has near-zero restaurant/chain coverage, so
`fatsecret_client.dart` adds FatSecret as a second live-search source. Unlike
OFF it is never called directly from the phone: the FatSecret secret lives
backend-side (`FATSECRET_*` env vars, `foods/fatsecret.py`), and
the proxy passes FatSecret's JSON through verbatim — all mapping to OFF-format
`nutriments_json` happens in `fatsecret_mapper.dart`. Same lazy
enrich-on-tap pattern as OFF (`foods.search` summaries → `food.get.v4`
detail); one process-wide FatSecret call budget
(`FatSecretClient.sharedLimiter` — shared by every client instance, but
never OFF's budget); results merge into the add-food ranked list as a
complementary source. The free tier
requires the "Powered by FatSecret" attribution the add-food page shows
whenever a FatSecret row is visible. Unconfigured backends return 503 and the
app degrades to OFF-only.

Auth mode is `FATSECRET_AUTH`: the default `oauth1` signs every request
(RFC 5849 two-legged HMAC-SHA1) and needs **no IP whitelisting** — FatSecret
only enforces its whitelist at the OAuth 2.0 token endpoint, which shared
egress (Render) can't satisfy without a paid dedicated IP. `oauth2` switches
to cached client-credentials tokens (`FATSECRET_SCOPE`) if OAuth 1.0 is ever
sunset; both modes use the same console credentials.

---

## Notable gaps / quirks

- **No shared Dio instance** — each API service constructs its own, then
  registers it with the shared `AuthInterceptor`. If more services are added
  this pattern should be centralised.
- **Hand-written JSON models** — `food_models.dart` and inline parsing in
  service files. No code generation.
- **Two on-device SQLite databases** with independent migration histories:
  `food_local_db.dart` (v8) and `nutrition_local_store.dart` (v2). Both files
  are namespaced per server user id (KAN-64, `local_db_paths.dart`): logout
  keeps them so offline data — including an unsynced outbox — survives
  re-login; account deletion clears them; the 3 most recently used accounts'
  files are kept per device (LRU eviction at shell startup).
- **Mirrored nutrient catalog** — `nutrients/catalog.py` (Python) and
  `nutrient_catalog.dart` (Dart) must change together; the backend test
  `test_nutrient_catalog_drift.py` fails on divergence.
- **No feature-level data layer except `nutrition/`** — as other features
  grow they should follow the same `data/` pattern.
