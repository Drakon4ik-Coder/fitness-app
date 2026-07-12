from django.conf import settings
from django.http import HttpRequest, JsonResponse


def assetlinks(request: HttpRequest) -> JsonResponse:
    """Serve /.well-known/assetlinks.json for Android Digital Asset Links.

    Declares (via the ``get_login_creds`` relation) that the configured Android
    app may share login credentials with this domain, so Google Password Manager
    offers the same saved password in both the website and the app instead of
    keying app credentials to the bare package name.

    Fingerprints are the public SHA-256 signing-cert values from
    ``ANDROID_CERT_FINGERPRINTS``; with none configured we return an empty
    statement list — valid JSON that simply asserts no association yet.
    """
    statements = []
    if settings.ANDROID_CERT_FINGERPRINTS:
        statements.append(
            {
                "relation": ["delegate_permission/common.get_login_creds"],
                "target": {
                    "namespace": "android_app",
                    "package_name": settings.ANDROID_APP_PACKAGE,
                    "sha256_cert_fingerprints": settings.ANDROID_CERT_FINGERPRINTS,
                },
            }
        )
    # safe=False: the top level is a list, as the Asset Links spec requires.
    return JsonResponse(statements, safe=False)
