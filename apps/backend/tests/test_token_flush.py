"""entrypoint.sh runs ``flushexpiredtokens`` with failures swallowed (a
stale-row backlog must never block serving traffic), so a broken or renamed
command would rot silently while the token_blacklist tables grow unbounded.
These tests pin the command's behaviour and the entrypoint wiring."""

from datetime import timedelta
from pathlib import Path

import pytest
from django.core.management import call_command
from django.utils import timezone
from rest_framework_simplejwt.token_blacklist.models import (
    BlacklistedToken,
    OutstandingToken,
)
from rest_framework_simplejwt.tokens import RefreshToken

from accounts.services import create_user_with_defaults

PASSWORD = "Str0ngPass!word"


@pytest.mark.django_db
def test_flushexpiredtokens_removes_expired_rows_and_keeps_live_ones() -> None:
    user = create_user_with_defaults(email="user@example.com", password=PASSWORD)
    expired = RefreshToken.for_user(user)
    live = RefreshToken.for_user(user)

    OutstandingToken.objects.filter(jti=expired["jti"]).update(
        expires_at=timezone.now() - timedelta(days=1)
    )
    # Blacklisted rows cascade with their OutstandingToken — an expired
    # refresh token is rejected on age alone, so its blacklist row is dead
    # weight too.
    expired.blacklist()

    call_command("flushexpiredtokens")

    assert set(OutstandingToken.objects.values_list("jti", flat=True)) == {live["jti"]}
    assert not BlacklistedToken.objects.exists()


def test_entrypoint_schedules_expired_token_flush() -> None:
    entrypoint = Path(__file__).resolve().parents[1] / "entrypoint.sh"
    assert "flushexpiredtokens" in entrypoint.read_text()
