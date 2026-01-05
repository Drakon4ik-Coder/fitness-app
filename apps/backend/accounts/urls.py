from django.urls import path
from rest_framework_simplejwt.views import TokenObtainPairView, TokenRefreshView

from accounts.views import MeView, RegisterView

urlpatterns = [
    path("register", RegisterView.as_view()),
    path("token", TokenObtainPairView.as_view()),
    path("refresh", TokenRefreshView.as_view()),
    path("me", MeView.as_view()),
]
