import hashlib
import secrets

from django.conf import settings
from django.contrib.auth.models import AbstractUser, BaseUserManager
from django.db import models
from django.db.models.functions import Lower
from django.utils import timezone


class UserManager(BaseUserManager):
    """User model manager that uses email as a unique identifier."""

    use_in_migrations = True

    def _create_user(self, email, password, **extra_fields):
        if not email:
            raise ValueError("Users must have an email address.")
        email = self.normalize_email(email)
        user = self.model(email=email, **extra_fields)
        user.set_password(password)  # None is unusable password from Oauth users
        user.save(using=self._db)
        return user

    def create_user(self, email, password=None, **extra_fields):
        extra_fields.setdefault("is_staff", False)
        extra_fields.setdefault("is_superuser", False)
        return self._create_user(email, password, **extra_fields)

    def create_superuser(self, email, password=None, **extra_fields):
        extra_fields.setdefault("is_staff", True)
        extra_fields.setdefault("is_superuser", True)
        if not extra_fields["is_staff"] or not extra_fields["is_superuser"]:
            raise ValueError("Superuser musy have is_staff and is_superuser True.")
        return self._create_user(email, password, **extra_fields)


class User(AbstractUser):
    email = models.EmailField("email address", unique=True)  # login identity

    # Case-insensitive unique @handle for forum/friends.
    # NULL until chosen (widens AbstractUser's non-null username).
    username = models.CharField(  # type: ignore[assignment]
        max_length=20, null=True, blank=True
    )

    display_name = models.CharField(max_length=40, blank=True)  # from Google name

    email_verified = models.BooleanField(default=False)

    USERNAME_FIELD = "email"
    REQUIRED_FIELDS = []

    objects = UserManager()  # type: ignore[misc,assignment]

    class Meta:
        constraints = [
            models.UniqueConstraint(Lower("username"), name="uniq_username_ci"),
        ]

    def __str__(self) -> str:
        return self.email


class EmailVerificationToken(models.Model):
    """Single-use, expiring token backing the email-verification link.

    Only the SHA-256 hash of the token is stored, so a database leak does not
    expose live links. The raw token travels only in the emailed URL.
    """

    user = models.ForeignKey(
        User, on_delete=models.CASCADE, related_name="verification_tokens"
    )
    token_hash = models.CharField(max_length=64, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)
    used_at = models.DateTimeField(null=True, blank=True)

    @staticmethod
    def hash_token(raw: str) -> str:
        return hashlib.sha256(raw.encode()).hexdigest()

    @classmethod
    def issue(cls, user: "User") -> str:
        """Create a token for ``user`` and return the raw value for the URL."""
        raw = secrets.token_urlsafe(32)
        cls.objects.create(user=user, token_hash=cls.hash_token(raw))
        return raw

    @property
    def is_expired(self) -> bool:
        return timezone.now() > self.created_at + settings.EMAIL_VERIFICATION_TTL

    def __str__(self) -> str:
        return f"verification for {self.user.email}"
