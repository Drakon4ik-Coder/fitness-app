from django.contrib import admin
from django.http import HttpRequest, JsonResponse
from django.urls import include, path
from drf_spectacular.views import SpectacularAPIView, SpectacularSwaggerView


def health(request: HttpRequest) -> JsonResponse:
    return JsonResponse({"status": "ok", "version": "0.1.0"})


urlpatterns = [
    path("admin/", admin.site.urls),
    path("health/", health, name="health"),
    path("api/schema/", SpectacularAPIView.as_view(), name="schema"),
    path(
        "api/docs/",
        SpectacularSwaggerView.as_view(url_name="schema"),
        name="swagger-ui",
    ),
    path("api/v1/auth/", include("accounts.urls")),
    path("api/v1/foods/", include("foods.urls")),
    path("api/v1/nutrition/", include("nutrition.urls")),
]
