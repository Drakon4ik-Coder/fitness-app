from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.http import HttpRequest, JsonResponse
from django.urls import include, path
from drf_spectacular.views import SpectacularAPIView, SpectacularSwaggerView

from accounts.views import confirm_account_deletion, request_account_deletion
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

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
