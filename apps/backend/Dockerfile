FROM python:3.12-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y build-essential && rm -rf /var/lib/apt/lists/*
WORKDIR /app

FROM base AS builder
RUN pip install --upgrade pip poetry poetry-plugin-export
COPY pyproject.toml poetry.lock* /app/
RUN poetry export -f requirements.txt --output requirements.txt --without-hashes
RUN poetry export --with dev -f requirements.txt --output requirements-dev.txt --without-hashes
RUN pip wheel --wheel-dir=/wheels -r requirements.txt

# runtime (prod)
FROM base AS runtime
RUN useradd -m appuser
COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir /wheels/*
COPY . /app
RUN chown -R appuser:appuser /app
USER appuser
ENV DJANGO_SETTINGS_MODULE=config.settings.prod
CMD ["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3", "--timeout", "60"]

# dev/test
FROM base AS dev
RUN useradd -m appuser
COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir /wheels/*
COPY --from=builder /app/requirements-dev.txt /tmp/requirements-dev.txt
RUN pip install --no-cache-dir -r /tmp/requirements-dev.txt
COPY . /app
RUN chown -R appuser:appuser /app
USER appuser
ENV DJANGO_SETTINGS_MODULE=config.settings.local
CMD ["python", "manage.py", "runserver", "0.0.0.0:8080"]
