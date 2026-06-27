BACKEND_DIR := apps/backend
MOBILE_DIR := apps/mobile
APP_ID := uk.drakon4ik.symbio

.PHONY: up migrate shell clean-db clean-mobile-db test test-docker build-prod \
	fmt lint check check-backend check-mobile fmt-backend fmt-mobile \
	lint-backend lint-mobile typecheck-backend test-backend test-mobile \
	backend-contract backend-install dev-phone dev-local

rebuild-backend:
	docker compose build --no-cache --pull backend
	docker compose up -d backend

rebuild-all:
	docker compose build --no-cache --pull
	docker compose up -d

dev-phone:
	./scripts/dev-phone.sh

dev-local:
	docker compose up --build -d
	@echo "Backend: http://localhost:8080"
	cd $(MOBILE_DIR) && flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080 --dart-define=GOOGLE_SERVER_CLIENT_ID=438442823657-527aqhqbf0ivtbtv39hv7t9tucfohg68.apps.googleusercontent.com

up:
	docker compose up --build -d

migrate:
	docker compose exec backend python manage.py migrate

shell:
	docker compose exec backend python manage.py shell

# Wipe ALL rows from every table (keeps schema/migrations). Irreversible.
clean-db:
	docker compose exec backend python manage.py flush --no-input
	@echo "Database data cleared."

# Delete the on-device local food cache (sqflite foods.db + journal/wal).
# Needs a debug build installed on a connected device/emulator and adb on PATH.
# The app recreates an empty DB on next launch.
clean-mobile-db:
	adb shell "run-as $(APP_ID) sh -c 'rm -f app_flutter/foods.db*'"
	@echo "Local food DB cleared. Restart the app to recreate it."

check:
	@echo "==> check"
	@$(MAKE) check-backend
	@$(MAKE) check-mobile

# Containerized tests (CI/CD)
test-docker:
	docker compose exec -e DJANGO_SETTINGS_MODULE=config.settings.test backend pytest -q

build-prod:
	docker build -f apps/backend/Dockerfile --target runtime -t fitness-backend:runtime apps/backend

fmt:
	@echo "==> fmt"
	@$(MAKE) fmt-backend
	@$(MAKE) fmt-mobile

lint:
	@echo "==> lint"
	@$(MAKE) lint-backend
	@$(MAKE) typecheck-backend
	@$(MAKE) lint-mobile

test:
	@echo "==> test"
	@$(MAKE) test-backend
	@$(MAKE) test-mobile

check-backend:
	@echo "==> check-backend"
	@$(MAKE) backend-install
	@$(MAKE) backend-contract
	@$(MAKE) lint-backend
	@$(MAKE) fmt-backend
	@$(MAKE) typecheck-backend
	@$(MAKE) test-backend

check-mobile:
	@echo "==> check-mobile"
	@cd $(MOBILE_DIR) && flutter pub get
	@cd $(MOBILE_DIR) && dart analyze
	@cd $(MOBILE_DIR) && flutter test

backend-install:
	@echo "==> backend-install"
	@cd $(BACKEND_DIR) && poetry install --no-interaction --no-root --sync

backend-contract:
	@echo "==> backend-contract"
	@cd $(BACKEND_DIR) && ./scripts/export_openapi.sh
	@cd $(BACKEND_DIR) && git diff --exit-code ../../contracts/openapi.yaml

fmt-backend:
	@echo "==> fmt-backend"
	@cd $(BACKEND_DIR) && poetry run ruff format --check .

fmt-mobile:
	@echo "==> fmt-mobile"
	@cd $(MOBILE_DIR) && dart format --set-exit-if-changed .

lint-backend:
	@echo "==> lint-backend"
	@cd $(BACKEND_DIR) && poetry run ruff check --output-format=github .

typecheck-backend:
	@echo "==> typecheck-backend"
	@cd $(BACKEND_DIR) && poetry run mypy .

lint-mobile:
	@echo "==> lint-mobile"
	@cd $(MOBILE_DIR) && flutter pub get
	@cd $(MOBILE_DIR) && dart analyze

test-backend:
	@echo "==> test-backend"
	@cd $(BACKEND_DIR) && poetry run pytest --maxfail=1 --disable-warnings -q

test-mobile:
	@echo "==> test-mobile"
	@cd $(MOBILE_DIR) && flutter pub get
	@cd $(MOBILE_DIR) && flutter test
