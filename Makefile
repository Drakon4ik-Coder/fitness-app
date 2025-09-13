.PHONY: up migrate shell test test-docker build-prod fmt

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

# Fast tests (local)
test:
	cd apps/backend && poetry run pytest -q

# Containerized tests (CI/CD)
test-docker:
	docker compose exec -e DJANGO_SETTINGS_MODULE=config.settings.test backend pytest -q

build-prod:
	docker build -f apps/backend/Dockerfile --target runtime -t fitness-backend:runtime apps/backend

fmt:
	cd apps/backend && pre-commit run --all-files
