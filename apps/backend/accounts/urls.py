from django.urls import path
from rest_framework_simplejwt.views import TokenRefreshView

from accounts.views import (
    MeView,
    PasswordResetRequestView,
    RegisterView,
    ResendVerificationView,
    EmailVerifiedTokenObtainPairView,
    GoogleLoginView,
    reset_password,
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
    path("password-reset", PasswordResetRequestView.as_view()),
    path("reset-password/<str:token>", reset_password, name="reset-password"),
]
