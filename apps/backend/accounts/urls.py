from django.urls import path
from rest_framework_simplejwt.views import TokenRefreshView

from accounts.views import (
    MeView,
    RegisterView,
    ResendVerificationView,
    EmailVerifiedTokenObtainPairView,
    GoogleLoginView,
    verify_email,
)

urlpatterns = [
    path("register", RegisterView.as_view()),
    path("token", EmailVerifiedTokenObtainPairView.as_view()),
    path("refresh", TokenRefreshView.as_view()),
    path("google", GoogleLoginView.as_view()),
    path("me", MeView.as_view()),
    path("verify/<str:token>", verify_email, name="verify-email"),
    path("resend-verification", ResendVerificationView.as_view()),
]
