from django.urls import path

from preferences.views import PreferencesView

urlpatterns = [
    path("", PreferencesView.as_view()),
]
