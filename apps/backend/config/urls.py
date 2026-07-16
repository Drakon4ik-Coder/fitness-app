import re
from urllib.parse import urlsplit

from django.conf import settings
from django.contrib import admin
from django.http import HttpRequest, HttpResponseBase, JsonResponse
from django.urls import include, path, re_path
from django.views.static import serve
from drf_spectacular.views import SpectacularAPIView, SpectacularSwaggerView

from accounts.views import (
    confirm_account_deletion,
    privacy_policy,
    request_account_deletion,
)
from config.well_known import assetlinks


def health(request: HttpRequest) -> JsonResponse:
    return JsonResponse({"status": "ok", "version": "0.1.0"})


urlpatterns = [
    path("admin/", admin.site.urls),
    path("health/", health, name="health"),
    # Domain-root well-known path Google fetches to affiliate the app with this
    # site for shared password autofill.
    path(".well-known/assetlinks.json", assetlinks, name="assetlinks"),
    # Domain-root web path for account deletion — Google Play's Data safety
    # form requires a deletion-request URL that works without the app.
    path("delete-account", request_account_deletion, name="delete-account"),
    path(
        "delete-account/<str:token>",
        confirm_account_deletion,
        name="delete-account-confirm",
    ),
    # Domain-root privacy policy — Play requires one hosted outside the app,
    # linked from the store listing and Settings → About.
    path("privacy", privacy_policy, name="privacy-policy"),
    path("api/schema/", SpectacularAPIView.as_view(), name="schema"),
    path(
        "api/docs/",
        SpectacularSwaggerView.as_view(url_name="schema"),
        name="swagger-ui",
    ),
    path("api/v1/auth/", include("accounts.urls")),
    path("api/v1/foods/", include("foods.urls")),
    path("api/v1/nutrition/", include("nutrition.urls")),
    path("api/v1/preferences/", include("preferences.urls")),
]


# Media must be served in production too, not just DEBUG: the food serializers
# hand out backend-hosted /media/ URLs whenever images_ok, and WhiteNoise only
# covers staticfiles — without this route every stored food image 404s once
# DEBUG is off. django.views.static.serve is discouraged for high-traffic
# media, but these are pre-validated ≤5 MB re-encoded JPEGs at hobby scale;
# revisit if a CDN/object store ever fronts the images.
# HttpResponseBase, not FileResponse: a conditional GET (If-Modified-Since)
# returns HttpResponseNotModified, which sits on the other branch of the
# response hierarchy.
def _serve_media(request: HttpRequest, path: str) -> HttpResponseBase:
    # MEDIA_ROOT is read per-request (not captured at URLconf import) so
    # override_settings works in tests.
    return serve(request, path, document_root=str(settings.MEDIA_ROOT))


# The prefix is derived from MEDIA_URL — the same derivation as
# django.conf.urls.static.static, which can't be used here because it no-ops
# when DEBUG is off — so URL generation (ImageField.url) and serving can't
# drift apart if a deployment relocates the media prefix. A MEDIA_URL with a
# netloc means a CDN/object store fronts the images and there is nothing
# local to serve. MEDIA_ROOT, by contrast, stays a per-request read inside
# _serve_media.
if settings.MEDIA_URL and not urlsplit(settings.MEDIA_URL).netloc:
    urlpatterns += [
        re_path(
            rf"^{re.escape(settings.MEDIA_URL.lstrip('/'))}(?P<path>.*)$",
            _serve_media,
        ),
    ]
