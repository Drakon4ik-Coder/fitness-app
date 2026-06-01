from django.urls import path
from rest_framework_simplejwt.views import TokenRefreshView

from accounts.views import MeView, RegisterView, EmailVerifiedTokenObtainPairView

urlpatterns = [
    path("register", RegisterView.as_view()),
    path("token", EmailVerifiedTokenObtainPairView.as_view()),
    path("refresh", TokenRefreshView.as_view()),
    path("me", MeView.as_view()),
]
