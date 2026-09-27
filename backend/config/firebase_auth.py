"""
Firebase Auth ID token verification for the /api/ surface.

Verifies Firebase ID tokens sent by the Flutter app so the backend can
trust claims like the verified phone number on a booking submission.

Enforcement is opt-in: this is a no-op unless
settings.FIREBASE_AUTH_ENFORCED is True (see settings.py). Until a Firebase
project is configured, no token is required.

Docs: https://firebase.google.com/docs/auth/admin/verify-id-tokens
"""
import logging

import firebase_admin
from django.conf import settings
from django.http import JsonResponse
from firebase_admin import auth

logger = logging.getLogger(__name__)

_firebase_app = None


def _get_firebase_app():
    global _firebase_app
    if _firebase_app is None:
        try:
            _firebase_app = firebase_admin.get_app()
        except ValueError:
            if not settings.FIREBASE_AUTH_ENFORCED:
                return None
            raise
    return _firebase_app


def verify_firebase_id_token(id_token):
    """Returns the decoded token claims, or raises Firebase Auth error."""
    app = _get_firebase_app()
    if app is None:
        raise RuntimeError('Firebase Admin SDK is not initialized.')
    return auth.verify_id_token(id_token)


class FirebaseAuthMiddleware:
    """Verifies Firebase ID tokens on protected endpoints.

    No-op unless settings.FIREBASE_AUTH_ENFORCED is True.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if settings.FIREBASE_AUTH_ENFORCED and request.path.startswith('/api/'):
            token = request.headers.get('X-Firebase-ID-Token')
            if not token:
                return JsonResponse({'detail': 'Missing Firebase ID token.'}, status=401)
            try:
                claims = verify_firebase_id_token(token)
                request.firebase_claims = claims
            except Exception as exc:
                logger.warning('Rejected request with invalid Firebase ID token: %s', exc)
                return JsonResponse({'detail': 'Invalid Firebase ID token.'}, status=401)
        return self.get_response(request)
