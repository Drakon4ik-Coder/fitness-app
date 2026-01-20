# Fitness App

[![Backend CI](https://github.com/Drakon4ik-Coder/fitness-app/actions/workflows/backend.yml/badge.svg)](https://github.com/Drakon4ik-Coder/fitness-app/actions/workflows/backend.yml)
[![Mobile CI](https://github.com/Drakon4ik-Coder/fitness-app/actions/workflows/mobile.yml/badge.svg)](https://github.com/Drakon4ik-Coder/fitness-app/actions/workflows/mobile.yml)
[![Meta CI](https://github.com/Drakon4ik-Coder/fitness-app/actions/workflows/ci-meta.yml/badge.svg)](https://github.com/Drakon4ik-Coder/fitness-app/actions/workflows/ci-meta.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

Monorepo for a Flutter mobile client and a Django/DRF backend for nutrition and fitness tracking.

## Table of contents
- [Overview](#overview)
- [Features](#features)
- [Monorepo structure](#monorepo-structure)
- [Tech stack](#tech-stack)
- [Prerequisites](#prerequisites)
- [Quickstart](#quickstart)
- [Environment variables](#environment-variables)
- [Testing and linting](#testing-and-linting)
- [API docs and contract workflow](#api-docs-and-contract-workflow)
- [CI/CD](#cicd)
- [Deployment](#deployment)
- [Release process](#release-process)
- [Data sources and attribution](#data-sources-and-attribution)
- [License](#license)
- [Contributing](#contributing)

## Overview
Flutter + Django monorepo focused on nutrition logging, food data ingestion, and a contract-first API.

See `docs/ARCHITECTURE.md` for design details and `docs/ROADMAP.md` for planned work.

## Features
Implemented:
- JWT auth endpoints (register, token, refresh, me).
- Nutrition and food APIs with Open Food Facts ingestion.
- OpenAPI schema and Swagger UI for API discovery.
- Flutter mobile app with login, nutrition, and barcode lookup flows.

Planned (see `docs/ROADMAP.md`):
- Recipes and meal planning.
- Workouts and training logs.
- Inventory and pantry management.
- Analytics and insights.
- Community features.

## Monorepo structure
```text
.
├─ apps/
│  ├─ backend/        # Django + DRF API
│  └─ mobile/         # Flutter app
├─ contracts/
│  └─ openapi.yaml    # Generated API contract
└─ docs/              # Architecture, development, roadmap, release
```

## Tech stack
- Mobile: Flutter, Dart, Riverpod, GoRouter, Dio, sqflite.
- Backend: Python 3.12, Django 5.2, Django REST Framework, SimpleJWT, drf-spectacular.
- Infra: Postgres 16, Redis 7, Docker Compose.
- Tooling: Poetry, Ruff, mypy, pytest, Dart analyzer, Flutter test.

## Prerequisites
- Docker + Docker Compose plugin (for local services).
- Python 3.12.
- Poetry.
- Flutter SDK (stable channel).

For local CI and prerequisites, also see `docs/DEVELOPMENT.md`.

## Quickstart
Backend (Docker Compose):
```bash
cp apps/backend/.env.example apps/backend/.env
make up
make migrate
```
Backend listens on `http://localhost:8080`.

Mobile:
```bash
cd apps/mobile
flutter pub get
flutter run --dart-define=API_BASE_URL=http://localhost:8080
```
Android emulator note: use `http://10.0.2.2:8080` instead of `localhost`.

## Environment variables
Backend (`apps/backend/.env`, see `apps/backend/.env.example`):

| Variable | Required | Notes |
| --- | --- | --- |
| DJANGO_SECRET_KEY | Yes (prod) | Development default is in `config/settings/base.py`. |
| DATABASE_URL | Yes | Compose uses `postgres://postgres:postgres@db:5432/fitness`. |
| DEBUG | No | Defaults to `true` in `.env.example`. |
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

## Testing and linting
All checks (mirrors CI and includes the OpenAPI contract check):
```bash
make check
```

Tests:
```bash
make test
```

Lint + typecheck:
```bash
make lint
```

Formatting checks:
```bash
make fmt
```

Per-module:
```bash
make check-backend
make check-mobile
```

## API docs and contract workflow
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

## CI/CD
- Pull requests: Backend CI and Mobile CI always run; steps are gated by relevant file changes. Meta CI always runs.
- Push to `main`: full backend + mobile + meta checks run every time.
- Nightly: full pipeline runs on a scheduled workflow.
- Manual runs: `workflow_dispatch` is enabled for all workflows.

## Deployment
- `render.yaml` defines a Render web service that builds `apps/backend/Dockerfile`.
- `apps/backend/entrypoint.sh` runs migrations and starts Gunicorn on `$PORT` (default 8000).
- Health check endpoint: `/health/`.
- Production env vars typically include `DJANGO_SETTINGS_MODULE=config.settings.prod`, `DJANGO_SECRET_KEY`, `DATABASE_URL`, and `CSRF_TRUSTED_ORIGINS`. `SENTRY_DSN` is optional.
- `MEDIA_ROOT` is local disk (`apps/backend/media`); plan for persistent storage in production if using uploads.

## Release process
See `docs/RELEASE.md` for tagging and release notes guidance.

## Data sources and attribution
Powered by Open Food Facts.

- Open Food Facts data is published under the Open Database License (ODbL). See https://world.openfoodfacts.org/data.
- Product images are typically under Creative Commons Attribution-ShareAlike (CC BY-SA). See https://world.openfoodfacts.org/terms-of-use.

When distributing the app or datasets, keep attribution and license notices intact.

## License
Licensed under the Apache License 2.0. See `LICENSE` and `NOTICE` for details.

## Contributing
- Use feature branches and keep PRs small.
- Run `make check` before opening a PR.
- If API changes, update `contracts/openapi.yaml`.
- Optional pre-push hook: `./scripts/install-githooks.sh`.
- Backend pre-commit config is in `apps/backend/.pre-commit-config.yaml` if you use `pre-commit`.
