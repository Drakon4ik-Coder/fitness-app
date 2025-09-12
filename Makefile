# fitness-app/Makefile
.PHONY: up migrate shell test fmt

up:
	docker compose up --build -d

migrate:
	docker compose exec backend python manage.py migrate

shell:
	docker compose exec backend python manage.py shell

test:
	cd apps/backend && poetry run pytest -q

fmt:
	cd apps/backend && pre-commit run --all-files
