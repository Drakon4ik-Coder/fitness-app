from django.contrib.auth.models import AbstractUser, BaseUserManager
from django.db import models
from django.db.models.functions import Lower


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
