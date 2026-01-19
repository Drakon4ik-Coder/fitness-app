# Fitness App

Monorepo for a Flutter mobile client and a Django/DRF backend for nutrition and fitness tracking.

## Table of contents
- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Tech stack](#tech-stack)
- [Getting started](#getting-started)
- [Local development](#local-development)
- [Running the app](#running-the-app)
- [Environment variables](#environment-variables)
- [Testing](#testing)
- [Formatting and linting](#formatting-and-linting)
- [API docs and contract](#api-docs-and-contract)
- [Deployment notes](#deployment-notes)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgements](#acknowledgements)

## Overview
Flutter + Django monorepo focused on nutrition logging, food data ingestion, and a contract-first API.

See `docs/ARCHITECTURE.md` for design details and `docs/ROADMAP.md` for planned work.

## Features
- JWT auth endpoints (register, token, refresh, me).
- Nutrition and food APIs with Open Food Facts ingestion.
- OpenAPI schema and Swagger UI for API discovery.
- Flutter mobile app with login, nutrition, and barcode lookup flows.

Planned (see `docs/ROADMAP.md`): recipes, workouts, inventory, analytics, community features.

## Architecture
Repo layout:

```text
.
├─ apps/
│  ├─ backend/        # Django + DRF API
│  └─ mobile/         # Flutter app
├─ contracts/
│  └─ openapi.yaml    # Generated API contract
└─ docs/              # Architecture, development, roadmap
```

Contract-first API: the backend generates `contracts/openapi.yaml`, and CI checks it is up to date.

## Tech stack
- Mobile: Flutter, Dart, Riverpod, GoRouter, Dio, sqflite.
- Backend: Python 3.12, Django 5.2, Django REST Framework, SimpleJWT, drf-spectacular.
- Infra: Postgres 16, Redis 7, Docker Compose.
- Tooling: Poetry, Ruff, mypy, pytest, Dart analyzer, Flutter test.

## Getting started
Prereqs:
- Docker + Docker Compose plugin (for local services).
- Python 3.12 (tested with 3.12.5).
- Poetry (backend tooling).
- Flutter SDK stable (tested with Flutter 3.35.3 / Dart 3.9.2).

For local CI and prerequisites, also see `docs/DEVELOPMENT.md`.

## Local development
1) Configure environment.
```bash
cp apps/backend/.env.example apps/backend/.env
```
Edit `apps/backend/.env` as needed.

2) Start backend services (Postgres, Redis, Django API).
```bash
make up
```
Backend listens on `http://localhost:8080`.

3) Apply migrations.
```bash
make migrate
```

4) Install backend deps for local tooling (tests, lint, typecheck).
```bash
make backend-install
```

5) Install mobile deps.
```bash
cd apps/mobile
flutter pub get
```

## Running the app
Backend (Docker Compose):
```bash
make up
make migrate
```

Mobile (override API base URL if using Docker Compose on 8080):
```bash
cd apps/mobile
flutter run --dart-define=API_BASE_URL=http://localhost:8080
```

Android emulator note: use `http://10.0.2.2:8080` instead of `localhost`.

## Environment variables
Backend (`apps/backend/.env`, see `apps/backend/.env.example`):

| Variable | Required | Notes |
| --- | --- | --- |
| DJANGO_SECRET_KEY | Yes (prod) | Development default is in `config/settings/base.py`. |
| DEBUG | No | Defaults to `true` in `.env.example`. |
| DATABASE_URL | Yes | Compose uses `postgres://postgres:postgres@db:5432/fitness`. |
| ALLOWED_HOSTS | No | Used by base/prod settings. |
| DJANGO_SETTINGS_MODULE | No | `config.settings.local` (dev), `config.settings.prod` (prod), `config.settings.test` (tests). |
| CSRF_TRUSTED_ORIGINS | No | Prod only, set in `config/settings/prod.py`. |
| SENTRY_DSN | No | Optional error reporting. |
| OFF_USER_AGENT | No | Open Food Facts user-agent string for image fetches. |

Mobile (Dart defines from `apps/mobile/lib/core/environment.dart`):

| Variable | Required | Notes |
| --- | --- | --- |
| APP_ENV | No | `local` (default), `staging`, `prod`. |
| API_BASE_URL | No | Overrides the base URL (defaults to `http://localhost:8000`). |
| OFF_USER_AGENT | No | Defaults to `FitnessApp/1.0`. |
| OFF_COUNTRY | No | Defaults to `en:united-kingdom`. |

Do not commit secrets. Keep local `.env` files out of version control and use `.env.example` as a template.

## Testing
All tests:
```bash
make test
```

Backend only:
```bash
make test-backend
```

Mobile only:
```bash
make test-mobile
```

Backend tests inside a running container:
```bash
make test-docker
```

## Formatting and linting
All checks (mirrors CI and includes the OpenAPI contract check):
```bash
make check
```

Format checks:
```bash
make fmt
```

Lint and typecheck:
```bash
make lint
```

Per-module:
```bash
make check-backend
make check-mobile
```

## API docs and contract
- Swagger UI: `http://localhost:8080/api/docs/`
- OpenAPI schema: `http://localhost:8080/api/schema/`
- Contract file: `contracts/openapi.yaml`

Regenerate the contract:
```bash
make backend-contract
```

Or directly:
```bash
cd apps/backend
./scripts/export_openapi.sh
```

CI expects `contracts/openapi.yaml` to be up to date.

## Deployment notes
- `render.yaml` defines a Render web service that builds `apps/backend/Dockerfile`.
- `apps/backend/entrypoint.sh` runs migrations and starts Gunicorn on `$PORT` (default 8000).
- Health check endpoint: `/health/`.
- Production env vars typically include `DJANGO_SETTINGS_MODULE=config.settings.prod`, `DJANGO_SECRET_KEY`, `DATABASE_URL`, and `CSRF_TRUSTED_ORIGINS`. `SENTRY_DSN` is optional.
- `MEDIA_ROOT` is local disk (`apps/backend/media`); plan for persistent storage in production if using uploads.

## Troubleshooting
- Mobile cannot reach backend: set `API_BASE_URL` and use `10.0.2.2` for Android emulators.
- Backend not reachable: confirm Docker is running and `make up` started the `backend` service on port 8080.
- Migrations missing: run `make migrate`.
- Missing `.env`: copy from `apps/backend/.env.example`.
- OpenAPI contract check failing: run `make backend-contract`.

## Contributing
- Use feature branches and keep PRs small.
- Run `make check` before opening a PR.
- If API changes, update `contracts/openapi.yaml`.
- Optional pre-push hook: `./scripts/install-githooks.sh`.
- Backend pre-commit config is in `apps/backend/.pre-commit-config.yaml` if you use `pre-commit`.

## License
No license file found. Add one before distributing or deploying publicly.

## Acknowledgements
Food data is powered by Open Food Facts. See https://world.openfoodfacts.org/.
