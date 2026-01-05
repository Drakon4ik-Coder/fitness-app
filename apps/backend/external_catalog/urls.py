from django.urls import path

from external_catalog.views import (
    ExternalFoodItemByBarcodeView,
    ExternalFoodItemIngestView,
)

urlpatterns = [
    path("foods/barcode/<str:barcode>", ExternalFoodItemByBarcodeView.as_view()),
    path("external/off/ingest", ExternalFoodItemIngestView.as_view()),
]
