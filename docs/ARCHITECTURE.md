# Architecture

## Repo layout

Monorepo. Everything lives under `apps/`:

```
fitness-app/
├── apps/
│   ├── backend/        # Django API
│   └── mobile/         # Flutter app
├── docker-compose.yml
├── docker-compose.prod.yml
├── Dockerfile
└── render.yaml         # Render.com deploy config
```

---

## Quick facts

| Concern | Answer |
|---|---|
| API style | **Django REST Framework** (`APIView` / `generics.*`; no plain Django views) |
| Auth | **SimpleJWT** — 5-min access token, 30-day refresh token |
| Database | **Postgres** via `DATABASE_URL` env var |
| API docs | Auto-generated via `drf-spectacular`; served at `/api/docs/` (Swagger UI) |
| Flutter state mgmt | **Plain `StatefulWidget` + `setState`**. One `ChangeNotifier` (`ThemeModeController`) for dark-mode toggling. `hooks_riverpod` is declared in `pubspec.yaml` but unused. |
| Flutter HTTP client | **Dio** (`^5.9.0`) |
| Flutter routing | **Imperative `Navigator`**. `go_router` is declared in `pubspec.yaml` but unused. Top-level auth routing is an `AuthGate` switch in `main.dart`. |
| Flutter JSON models | **Hand-written** — no `json_serializable` or `freezed` |

---

## Backend — Django apps

Project package: `apps/backend/config/`
Settings are layered: `config/settings/{base,local,prod,test}.py`
Root URLconf: `config/urls.py`

### Apps

| App | Models | Has views/serializers/urls | Purpose |
|---|---|---|---|
| `accounts/` | none (uses Django's built-in `User`) | yes / yes / yes | Registration, login, `/me` |
| `preferences/` | `UserPreferences` | no / no / no | Per-user settings storage |
| `foods/` | `FoodItem` | yes / yes / yes | Food catalog (OpenFoodFacts-sourced) |
| `nutrition/` | `MealEntry` | yes / yes / yes | Logging meals and daily totals |
| `nutrients/` | `NutrientDefinition` | no / no / no | Nutrient reference data |

### Key views

`accounts/views.py`
- `RegisterView` (generics.CreateAPIView)
- `MeView` (APIView)

`foods/views.py`
- `FoodTypeaheadView` — name-based search
- `FoodIngestView` — import a food from OpenFoodFacts
- `FoodCheckView` — check if a barcode exists
- `FoodImageUploadView` — multipart image upload for a food item

`nutrition/views.py`
- `MealEntryCreateView` — log a meal
- `NutritionDayView` — fetch totals for a given date

### URL mounts (`config/urls.py`)

| Prefix | App |
|---|---|
| `/api/v1/auth/` | `accounts.urls` (register, token, refresh, me) |
| `/api/v1/foods/` | `foods.urls` (typeahead, ingest, check, `<id>/images`) |
| `/api/v1/nutrition/` | `nutrition.urls` (entries, day) |
| `/api/schema/` | drf-spectacular OpenAPI schema |
| `/api/docs/` | Swagger UI |
| `/admin/` | Django admin |
| `/health/` | JSON healthcheck |

---

## Frontend — Flutter feature folders

All source lives under `apps/mobile/lib/`.

```
lib/
├── main.dart                   # FitnessApp + AuthGate (login ↔ NutritionTodayPage)
├── core/
│   ├── auth_service.dart       # login / register / logout, JWT exchange
│   ├── auth_interceptor.dart   # Dio interceptor: attaches token, handles 401 refresh
│   ├── auth_storage.dart       # flutter_secure_storage wrapper (access + refresh keys)
│   └── environment.dart        # apiBaseUrl resolved from --dart-define=APP_ENV
├── features/
│   ├── login_page.dart
│   ├── register_page.dart
│   ├── barcode_lookup_page.dart
│   └── nutrition/
│       ├── nutrition_today_page.dart
│       ├── add_food_page.dart
│       ├── nutrition_scan_page.dart
│       └── data/
│           ├── nutrition_api_service.dart   # /api/v1/nutrition/* calls
│           ├── foods_api_service.dart       # /api/v1/foods/* calls
│           ├── food_models.dart             # FoodItem + JSON parsing helpers
│           ├── food_local_db.dart           # sqflite cache
│           ├── off_client.dart              # OpenFoodFacts API client
│           ├── off_mapper.dart              # OFF response → FoodItem
│           ├── off_image_downloader.dart
│           ├── off_rate_limiter.dart
│           └── api_exceptions.dart
├── ui_components/              # Shared widgets (AppScaffold, buttons, fields, etc.)
└── ui_system/                  # Theming: tokens, AppTheme, ThemeModeController
```

Only `features/nutrition/` has a `data/` layer; other features are single-file pages.

---

## How the two sides talk

### Transport

The Flutter app talks to the Django backend over HTTPS using Dio.
Base URL is chosen at build time via `--dart-define=APP_ENV`:

| ENV | URL |
|---|---|
| `local` | `http://localhost:8000` |
| `staging` | Render staging URL |
| `prod` | `https://symbio.drakon4ik.uk` |

Each API service (`nutrition_api_service.dart`, `foods_api_service.dart`) creates its own `Dio` instance and calls `authInterceptor?.attachTo(_dio)` to wire up auth.

### JWT lifecycle

1. **Login** — `AuthService.login()` posts to `/api/v1/auth/token` and stores the returned `access` + `refresh` tokens via `AuthStorage` (`flutter_secure_storage`).
2. **Every request** — `AuthInterceptor.onRequest` reads the access token and attaches `Authorization: Bearer <token>`.
3. **On 401** — the interceptor calls the backend's `/api/v1/auth/refresh` endpoint (deduplicated — concurrent 401s share one refresh future), stores the new token, updates all attached `Dio` instances, then replays the original request transparently.
4. **Refresh failure** — fires `onSessionExpired`, which calls `_AuthGateState._handleLogout` in `main.dart`, returning the user to `LoginPage`.
5. **Backend side** — `TokenObtainPairView` / `TokenRefreshView` from `rest_framework_simplejwt` are mounted in `accounts/urls.py`. Token lifetimes configured in `config/settings/base.py`.

### Endpoint map

| Mobile call | Backend view |
|---|---|
| `POST /api/v1/auth/token` | `TokenObtainPairView` |
| `POST /api/v1/auth/refresh` | `TokenRefreshView` |
| `POST /api/v1/auth/register` | `RegisterView` |
| `GET /api/v1/auth/me` | `MeView` |
| `GET /api/v1/foods/typeahead` | `FoodTypeaheadView` |
| `POST /api/v1/foods/ingest` | `FoodIngestView` |
| `GET /api/v1/foods/check` | `FoodCheckView` |
| `POST /api/v1/foods/<id>/images` | `FoodImageUploadView` |
| `POST /api/v1/nutrition/entries` | `MealEntryCreateView` |
| `GET /api/v1/nutrition/day` | `NutritionDayView` |

### OpenFoodFacts — called from both sides

The mobile app queries OFF directly via `off_client.dart` (barcode lookup, food search) and uploads the resulting image to the backend via `foods_api_service.dart`. The backend uses the same source (`SOURCE_OPEN_FOOD_FACTS` constant in `foods/models.py`) when ingesting or checking foods server-side.

---

## Notable gaps / quirks

- **`hooks_riverpod` and `go_router`** are in `pubspec.yaml` but not used. Likely placeholders for planned refactors.
- **No shared Dio instance** — each API service constructs its own, then registers it with the shared `AuthInterceptor`. If more services are added this pattern should be centralised.
- **Hand-written JSON models** — `food_models.dart` and inline parsing in service files. No code generation.
- **No feature-level data layer except `nutrition/`** — as other features grow (e.g. a dedicated profile or preferences page) they'll need a `data/` folder following the same pattern.
