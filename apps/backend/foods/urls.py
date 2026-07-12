from django.urls import path

from foods.views import (
    CustomFoodDetailView,
    CustomFoodView,
    FoodCheckView,
    FoodImageUploadView,
    FoodIngestView,
    FoodTypeaheadView,
)

urlpatterns = [
    path("typeahead", FoodTypeaheadView.as_view()),
    path("ingest", FoodIngestView.as_view()),
    path("custom", CustomFoodView.as_view()),
    path("custom/<int:food_item_id>", CustomFoodDetailView.as_view()),
    path("check", FoodCheckView.as_view()),
    path("<int:food_item_id>/images", FoodImageUploadView.as_view()),
]
