from django.urls import path

from nutrition.views import (
    MealEntryCreateView,
    MealEntryDetailView,
    MealEntrySyncView,
    MealTimesView,
    NutritionDayView,
)

urlpatterns = [
    path("entries", MealEntryCreateView.as_view()),
    path("entries/sync", MealEntrySyncView.as_view()),
    path("entries/<int:pk>", MealEntryDetailView.as_view()),
    # Offline replays address entries by their client-generated uuid — a queued
    # edit may target an entry the server hadn't assigned a pk to yet.
    path("entries/by-uuid/<uuid:client_uuid>", MealEntryDetailView.as_view()),
    path("day", NutritionDayView.as_view()),
    path("meal-times", MealTimesView.as_view()),
]
