from .base import *

DEBUG = False
ALLOWED_HOSTS = ["testserver", "localhost", "127.0.0.1"]

# Use fast, in-memory DB for unit tests
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": ":memory:",
    }
}

# Speed up tests
PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]
EMAIL_BACKEND = "django.core.mail.backends.locmem.EmailBackend"

GOOGLE_OAUTH_CLIENT_IDS = ["test-client-id"]

# Throttles share a process-wide cache that would otherwise leak between
# tests; disable by default and re-enable per-test where rate limiting is the
# thing under test.
REST_FRAMEWORK = {
    **REST_FRAMEWORK,
    "DEFAULT_THROTTLE_RATES": {
        "anon": None,
        "user": None,
        "resend_verification": None,
        "password_reset": None,
        "login": None,
        "register": None,
        "google": None,
    },
}
