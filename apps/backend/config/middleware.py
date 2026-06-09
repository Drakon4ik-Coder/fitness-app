from collections.abc import Callable

from django.conf import settings
from django.http import HttpRequest, HttpResponse


class CloudflareClientIPMiddleware:
    """Rewrite REMOTE_ADDR to the real client IP behind a Cloudflare Tunnel.

    With a Tunnel (cloudflared), every request reaches the origin over the
    local tunnel connection, so REMOTE_ADDR is that tunnel address — the same
    value for every visitor, which makes per-IP rate limiting meaningless.
    Cloudflare puts the originating client IP in the CF-Connecting-IP header.

    We can trust that header because the origin is only reachable through the
    Tunnel (no public inbound port), so a client can't bypass Cloudflare to
    forge it. The behaviour is gated on USE_CLOUDFLARE_CLIENT_IP so that any
    environment NOT behind Cloudflare never trusts an attacker-supplied header.
    The setting is read per request (not cached at init) so test overrides and
    config reloads take effect without rebuilding the middleware stack.
    """

    def __init__(self, get_response: Callable[[HttpRequest], HttpResponse]) -> None:
        self.get_response = get_response

    def __call__(self, request: HttpRequest) -> HttpResponse:
        if getattr(settings, "USE_CLOUDFLARE_CLIENT_IP", False):
            client_ip = request.META.get("HTTP_CF_CONNECTING_IP")
            if client_ip:
                request.META["REMOTE_ADDR"] = client_ip
        return self.get_response(request)
