from __future__ import annotations

from typing import TYPE_CHECKING

from django.conf import settings
from rest_framework.exceptions import PermissionDenied
from rest_framework.permissions import BasePermission

if TYPE_CHECKING:
    # Typing-only: this module is imported by DEFAULT_PERMISSION_CLASSES
    # resolution *inside* rest_framework.views' own initialization, so a
    # runtime import of APIView here would be circular.
    from rest_framework.request import Request
    from rest_framework.views import APIView


class PolicyConsentAccepted(BasePermission):
    """Refuses API use until the user has accepted the current policy version
    (KAN-103).

    GDPR Art. 9 / Play Health policy: the nutrition diary is health data, so
    processing it requires recorded, affirmative consent — passive display of
    the policy is not enough. The check reads the denormalized
    ``User.accepted_policy_version`` (JWT auth already loaded the row), so the
    gate costs zero extra queries per request.

    Deliberately NOT applied to the auth flows (register/token/refresh/google,
    verification, password flows), ``/auth/me`` (the app reads policy state
    from it to drive the consent screen; DELETE is the consent-withdrawal
    path) or ``accept-policy`` itself — those views declare their own
    permission_classes without this gate.
    """

    def has_permission(self, request: Request, view: APIView) -> bool:
        user = request.user
        # Anonymous requests fall through to IsAuthenticated's 401; this gate
        # only ever has a verdict for real users.
        if user is None or not user.is_authenticated:
            return True
        if user.accepted_policy_version == settings.POLICY_VERSION:
            return True
        # A dict detail becomes the response body verbatim, so the app gets a
        # stable machine-readable code to tell "must (re-)consent" apart from
        # ordinary permission failures.
        raise PermissionDenied(
            {
                "detail": "You must accept the current Terms of Service and "
                "Privacy Policy to continue.",
                "code": "policy_consent_required",
            }
        )
