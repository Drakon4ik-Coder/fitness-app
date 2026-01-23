from django.urls import path

from foods.views import FoodCheckView, FoodIngestView, FoodTypeaheadView

urlpatterns = [
    path("typeahead", FoodTypeaheadView.as_view()),
    path("ingest", FoodIngestView.as_view()),
    path("check", FoodCheckView.as_view()),
]
