BACKEND_DIR := apps/backend
MOBILE_DIR := apps/mobile

.PHONY: up migrate shell test test-docker build-prod fmt lint check \
	check-backend check-mobile fmt-backend fmt-mobile lint-backend lint-mobile \
	typecheck-backend test-backend test-mobile backend-contract backend-install

rebuild-backend:
	docker compose build --no-cache --pull backend
	docker compose up -d backend

rebuild-all:
	docker compose build --no-cache --pull
	docker compose up -d

up:
	docker compose up --build -d

migrate:
	docker compose exec backend python manage.py migrate

shell:
	docker compose exec backend python manage.py shell

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
