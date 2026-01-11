from django.urls import path

from foods.views import FoodIngestView, FoodTypeaheadView

urlpatterns = [
    path("typeahead", FoodTypeaheadView.as_view()),
    path("ingest", FoodIngestView.as_view()),
]
