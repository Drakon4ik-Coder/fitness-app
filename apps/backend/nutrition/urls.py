from django.urls import path

from nutrition.views import MealEntryCreateView, NutritionDayView

urlpatterns = [
    path("entries", MealEntryCreateView.as_view()),
    path("day", NutritionDayView.as_view()),
]
