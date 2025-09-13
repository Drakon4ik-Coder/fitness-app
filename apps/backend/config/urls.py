from django.contrib import admin
from django.urls import path
from django.http import HttpRequest, JsonResponse


def health(request: HttpRequest) -> JsonResponse:
    return JsonResponse({"status": "ok", "version": "0.1.0"})


urlpatterns = [
    path("admin/", admin.site.urls),
    path("health/", health, name="health"),
]
