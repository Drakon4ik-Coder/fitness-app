from django.urls import path

from nutrition.views import (
    MealEntryCreateView,
    MealEntryDetailView,
    NutritionDayView,
)

urlpatterns = [
    path("entries", MealEntryCreateView.as_view()),
    path("entries/<int:pk>", MealEntryDetailView.as_view()),
    path("day", NutritionDayView.as_view()),
]
