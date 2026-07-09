import os
from datetime import timedelta
from pathlib import Path
from typing import Any

import environ
import sentry_sdk

env = environ.Env()
environ.Env.read_env(os.path.join(Path(__file__).resolve().parents[2], ".env"))

BASE_DIR = Path(__file__).resolve().parents[2]

SECRET_KEY = env("DJANGO_SECRET_KEY", default="dev-not-secure")
DEBUG = env.bool("DEBUG", default=True)
ALLOWED_HOSTS = env.list("ALLOWED_HOSTS", default=["*"])

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "rest_framework",
    "drf_spectacular",
    "rest_framework_simplejwt",
    "accounts",
    "preferences",
    "foods",
    "nutrition",
    "nutrients",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    # Must run before anything that reads the client IP (e.g. DRF throttling).
    "config.middleware.CloudflareClientIPMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "config.urls"
TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ]
        },
    }
]

WSGI_APPLICATION = "config.wsgi.application"

DATABASES = {
    "default": env.db(
        "DATABASE_URL", default="postgres://postgres:postgres@localhost:5432/fitness"
    )
}

AUTH_USER_MODEL = "accounts.User"

# Password validation
# https://docs.djangoproject.com/en/5.2/ref/settings/#auth-password-validators

AUTH_PASSWORD_VALIDATORS = [
    {
        "NAME": "django.contrib.auth.password_validation."
        "UserAttributeSimilarityValidator",
    },
    {
        "NAME": "django.contrib.auth.password_validation.MinimumLengthValidator",
    },
    {
        "NAME": "django.contrib.auth.password_validation.CommonPasswordValidator",
    },
    {
        "NAME": "django.contrib.auth.password_validation.NumericPasswordValidator",
    },
]


# Internationalization
# https://docs.djangoproject.com/en/5.2/topics/i18n/

LANGUAGE_CODE = "en-us"

TIME_ZONE = "UTC"

USE_I18N = True

USE_TZ = True


# Static files (CSS, JavaScript, Images)
# https://docs.djangoproject.com/en/5.2/howto/static-files/

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
MEDIA_URL = "/media/"
MEDIA_ROOT = BASE_DIR / "media"

# Default primary key field type
# https://docs.djangoproject.com/en/5.2/ref/settings/#default-auto-field

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

REST_FRAMEWORK: dict[str, Any] = {
    "DEFAULT_AUTHENTICATION_CLASSES": (
        "rest_framework_simplejwt.authentication.JWTAuthentication",
    ),
    "DEFAULT_PERMISSION_CLASSES": ("rest_framework.permissions.IsAuthenticated",),
    "DEFAULT_SCHEMA_CLASS": "drf_spectacular.openapi.AutoSchema",
    # Baseline throttles applied to every DRF view that doesn't set its own:
    # "anon" keys by client IP, "user" by account id. This is app-level abuse
    # hygiene (a speed bump against a single script), NOT DDoS protection —
    # volumetric defense belongs at the edge (proxy / Cloudflare / WAF).
    # Views with their own throttle_classes (login, register, etc.) override
    # these rather than stacking with them.
    "DEFAULT_THROTTLE_CLASSES": (
        "rest_framework.throttling.AnonRateThrottle",
        "rest_framework.throttling.UserRateThrottle",
    ),
    "DEFAULT_THROTTLE_RATES": {
        "anon": "20/min",
        "user": "100/min",
        # Tighter per-view scopes for sensitive anonymous endpoints.
        "resend_verification": "2/day",  # sends an email per call
        "password_reset": "3/hour",  # sends an email per call
        "login": "5/min",  # credential brute-force / password spray
        "register": "2/min",  # sends a verification email per call
        "google": "10/min",  # outbound token verification to Google per call
        # Keyed by user id (authenticated): the re-auth check verifies the
        # password / Google token, so cap attempts against a stolen access
        # token being used to brute-force the deletion re-auth.
        "account_delete": "5/hour",
    },
}

# Behind a Cloudflare Tunnel the origin only ever sees the tunnel's address in
# REMOTE_ADDR, so CloudflareClientIPMiddleware rewrites it from the trusted
# CF-Connecting-IP header (see config/middleware.py). When that's on, also pin
# DRF's IP resolution to REMOTE_ADDR (NUM_PROXIES=0) so it uses our corrected
# value instead of the X-Forwarded-For header Cloudflare also appends.
USE_CLOUDFLARE_CLIENT_IP = env.bool("USE_CLOUDFLARE_CLIENT_IP", default=False)
if USE_CLOUDFLARE_CLIENT_IP:
    REST_FRAMEWORK["NUM_PROXIES"] = 0

SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=5),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=30),
}

SPECTACULAR_SETTINGS = {
    "TITLE": "Fitness API",
    "DESCRIPTION": "Fitness App API",
    "VERSION": "0.1.0",
    "SERVE_PERMISSIONS": ["rest_framework.permissions.AllowAny"],
    "SERVE_AUTHENTICATION": [],
}

SENTRY_DSN = env("SENTRY_DSN", default="").strip() or None

if SENTRY_DSN:
    sentry_sdk.init(
        dsn=SENTRY_DSN,
        traces_sample_rate=0.1,
    )

GOOGLE_OAUTH_CLIENT_IDS = env.list("GOOGLE_OAUTH_CLIENT_IDS", default=[])

# Email
# Local/dev defaults to the console backend (emails print to the runserver
# logs). Prod overrides EMAIL_BACKEND to SMTP via env. The same env vars work
# for Gmail (smtp.gmail.com + App Password) or any custom-domain SMTP provider,
# so switching senders later is an env change with no code change.
# EMAIL_BACKEND = env(
#     "EMAIL_BACKEND",
#     default="django.core.mail.backends.console.EmailBackend",
# )
EMAIL_HOST = env("EMAIL_HOST", default="smtp.gmail.com")
EMAIL_PORT = env.int("EMAIL_PORT", default=587)
EMAIL_USE_TLS = env.bool("EMAIL_USE_TLS", default=True)
EMAIL_HOST_USER = env("EMAIL_HOST_USER", default="")
EMAIL_HOST_PASSWORD = env("EMAIL_HOST_PASSWORD", default="")
DEFAULT_FROM_EMAIL = env(
    "DEFAULT_FROM_EMAIL", default=EMAIL_HOST_USER or "noreply@drakon4ik.uk"
)

# How long an emailed verification link stays valid.
EMAIL_VERIFICATION_TTL = timedelta(
    hours=env.int("EMAIL_VERIFICATION_TTL_HOURS", default=24)
)

# How long an emailed password-reset link stays valid. Shorter than the
# verification TTL because it grants a credential change.
PASSWORD_RESET_TTL = timedelta(hours=env.int("PASSWORD_RESET_TTL_HOURS", default=1))

# How long an emailed account-deletion link stays valid. Short like the reset
# TTL: it authorizes an irreversible action.
ACCOUNT_DELETION_TTL = timedelta(hours=env.int("ACCOUNT_DELETION_TTL_HOURS", default=1))

# Absolute base URL used to build verification links in emails. When empty we
# fall back to the host of the incoming request (correct in prod behind the
# public domain; fine in dev with the console email backend).
PUBLIC_BASE_URL = env("PUBLIC_BASE_URL", default="").rstrip("/")

# Android Digital Asset Links, served at /.well-known/assetlinks.json. Declaring
# the app here lets Google Password Manager share a saved login between this
# website and the app (so the same credential autofills in both). The
# fingerprints are the SHA-256 of each signing certificate (debug, upload, and
# Play App Signing) — public values, supplied comma-separated. With none set the
# endpoint returns an empty statement list (valid JSON that asserts nothing).
ANDROID_APP_PACKAGE = env("ANDROID_APP_PACKAGE", default="uk.drakon4ik.symbio")
ANDROID_CERT_FINGERPRINTS = env.list("ANDROID_CERT_FINGERPRINTS", default=[])
