from pathlib import Path
import environ

BASE_DIR = Path(__file__).resolve().parent.parent

env = environ.Env(DEBUG=(bool, False))
environ.Env.read_env(BASE_DIR / '.env')

SECRET_KEY = env('SECRET_KEY')
DEBUG = env('DEBUG')
ALLOWED_HOSTS = env.list('ALLOWED_HOSTS', default=['localhost', '127.0.0.1'])
CSRF_TRUSTED_ORIGINS = [
    f'https://{host}' for host in ALLOWED_HOSTS
    if host not in ('*', 'localhost') and not host.startswith('127.')
]

# Cloud Run terminates TLS at its proxy and forwards requests to the
# container over plain HTTP, setting X-Forwarded-Proto to indicate the
# original scheme. Without this, request.is_secure() always returns False,
# which breaks CSRF's same-origin check (it compares the browser's real
# `Origin: https://...` header against a `http://...` guess) for every POST
# on the site, including admin login.
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')

INSTALLED_APPS = [
    "unfold",
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'rest_framework',
    'rest_framework_simplejwt',
    'corsheaders',
    'services',
    'bookings',
    'vendors',
    'payments',
    'terms',
    'reviews',
    'analytics',
    'api',
    'accounts',
]

UNFOLD = {
    "SITE_TITLE": "AnyBooking Admin",
    "STYLES": [lambda request: "/static/css/admin_custom.css"],
    "SITE_HEADER": "AnyBooking",
    "SITE_SUBHEADER": "Event Booking Platform",
    "SITE_URL": "/",
    "SITE_ICON": None,
    "COLORS": {
        "primary": {
            "50": "240 249 255",
            "100": "224 242 254",
            "200": "186 230 253",
            "300": "125 211 252",
            "400": "56 189 248",
            "500": "14 165 233",
            "600": "2 132 199",
            "700": "3 105 161",
            "800": "7 89 133",
            "900": "12 74 110",
            "950": "8 47 73",
        },
    },
    "SIDEBAR": {
        "show_search": True,
        "show_all_applications": True,
        "navigation": [
            {
                "title": "Overview",
                "items": [
                    {"title": "Dashboard", "icon": "dashboard", "link": "/admin/dashboard/"},
                ],
            },
            {
                "title": "Bookings",
                "items": [
                    {"title": "Bookings", "icon": "calendar_month", "link": "/admin/bookings/booking/"},
                    {"title": "Blocked Dates", "icon": "event_busy", "link": "/admin/bookings/blockeddate/"},
                    {"title": "Email Logs", "icon": "mail", "link": "/admin/bookings/emaillog/"},
                ],
            },
            {
                "title": "Services",
                "items": [
                    {"title": "Services", "icon": "storefront", "link": "/admin/services/service/"},
                    {"title": "Vendors", "icon": "person", "link": "/admin/services/vendor/"},
                    {"title": "Categories", "icon": "category", "link": "/admin/services/category/"},
                    {"title": "Attributes", "icon": "tune", "link": "/admin/services/attributedefinition/"},
                    {"title": "Home Background Images", "icon": "wallpaper", "link": "/admin/services/homebackgroundimage/"},
                ],
            },
            {
                "title": "Reviews",
                "items": [
                    {"title": "Reviews", "icon": "star", "link": "/admin/reviews/review/"},
                ],
            },
            {
                "title": "Locations",
                "items": [
                    {"title": "Countries", "icon": "public", "link": "/admin/services/country/"},
                    {"title": "States", "icon": "map", "link": "/admin/services/state/"},
                    {"title": "Districts", "icon": "location_city", "link": "/admin/services/district/"},
                    {"title": "Cities", "icon": "place", "link": "/admin/services/city/"},
                ],
            },
            {
                "title": "Payments",
                "items": [
                    {"title": "Payments", "icon": "payments", "link": "/admin/payments/payment/"},
                    {"title": "Gateway Configs", "icon": "settings", "link": "/admin/payments/paymentgatewayconfig/"},
                ],
            },
            {
                "title": "Configuration",
                "items": [
                    {"title": "Terms of Use", "icon": "gavel", "link": "/admin/terms/termsofuse/"},
                    {"title": "Regional Configs", "icon": "translate", "link": "/admin/services/regionalcategoryconfig/"},
                    {"title": "Staff Profiles", "icon": "badge", "link": "/admin/services/staffprofile/"},
                ],
            },
            {
                "title": "Users",
                "items": [
                    {"title": "Users", "icon": "manage_accounts", "link": "/admin/auth/user/"},
                    {"title": "Groups", "icon": "group", "link": "/admin/auth/group/"},
                ],
            },
        ],
    },
}

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'whitenoise.middleware.WhiteNoiseMiddleware',
    'corsheaders.middleware.CorsMiddleware',
    'config.app_check.AppCheckMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'config.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [BASE_DIR / 'templates'],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
                'services.context_processors.nav_categories',
                'bookings.context_processors.customer_identity',
            ],
        },
    },
]

WSGI_APPLICATION = 'config.wsgi.application'

DATABASES = {
    'default': env.db('DATABASE_URL', default=f'sqlite:///{BASE_DIR}/db.sqlite3')
}

AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]

LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'Asia/Kolkata'
USE_I18N = True
USE_TZ = True

STATIC_URL = '/static/'
STATICFILES_DIRS = [BASE_DIR / 'static']
STATIC_ROOT = BASE_DIR / 'staticfiles'

MEDIA_URL = '/media/'
MEDIA_ROOT = BASE_DIR / 'media'

# `staticfiles` must always use the manifest storage so the manifest generated
# by `collectstatic` at Docker build time matches the storage used at runtime.
# `default` (media) switches to GCS only when a bucket is configured, since
# collectstatic doesn't need it and we don't want it to depend on env at build time.
GCS_MEDIA_BUCKET = env('GCS_MEDIA_BUCKET', default='')
STORAGES = {
    'default': (
        {
            'BACKEND': 'storages.backends.gcloud.GoogleCloudStorage',
            'OPTIONS': {'bucket_name': GCS_MEDIA_BUCKET},
        } if GCS_MEDIA_BUCKET else
        {'BACKEND': 'django.core.files.storage.FileSystemStorage'}
    ),
    'staticfiles': {
        'BACKEND': 'whitenoise.storage.CompressedManifestStaticFilesStorage',
    },
}

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

RAZORPAY_KEY_ID = env('RAZORPAY_KEY_ID', default='')
RAZORPAY_KEY_SECRET = env('RAZORPAY_KEY_SECRET', default='')

GROQ_API_KEY = env('GROQ_API_KEY', default='')
GROQ_MODEL = env('GROQ_MODEL', default='openai/gpt-oss-20b')

LOGIN_URL = '/admin/login/'

# ── Email ──────────────────────────────────────────────────────────────────────
# If Brevo SMTP credentials are configured (BREVO_SMTP_*), emails are sent via
# Brevo automatically. Otherwise they print to the console (dev default).
# Any value can be overridden explicitly via EMAIL_* env vars (production).
_brevo_user = env('BREVO_SMTP_USER', default='')
_brevo_configured = bool(_brevo_user and env('BREVO_SMTP_PASSWORD', default=''))
EMAIL_BACKEND = env(
    'EMAIL_BACKEND',
    default=(
        'django.core.mail.backends.smtp.EmailBackend'
        if _brevo_configured else
        'django.core.mail.backends.console.EmailBackend'
    ),
)
EMAIL_HOST = env('EMAIL_HOST', default=env('BREVO_SMTP_HOST', default='smtp-relay.brevo.com'))
EMAIL_PORT = env.int('EMAIL_PORT', default=env.int('BREVO_SMTP_PORT', default=587))
EMAIL_USE_TLS = env.bool('EMAIL_USE_TLS', default=True)
EMAIL_HOST_USER = env('EMAIL_HOST_USER', default=_brevo_user)
EMAIL_HOST_PASSWORD = env('EMAIL_HOST_PASSWORD', default=env('BREVO_SMTP_PASSWORD', default=''))
DEFAULT_FROM_EMAIL = env('DEFAULT_FROM_EMAIL', default=env('BREVO_FROM_EMAIL', default='AnyBooking <noreply@anybooking.in>'))

# Super-admin notification email (receives all new booking alerts)
ADMIN_NOTIFY_EMAIL = env('ADMIN_NOTIFY_EMAIL', default='')

# Public site base URL — used to build links in emails
SITE_URL = env('SITE_URL', default='http://127.0.0.1:8000')

# ── Django REST Framework ───────────────────────────────────────────────────────
REST_FRAMEWORK = {
    'DEFAULT_AUTHENTICATION_CLASSES': (
        'rest_framework_simplejwt.authentication.JWTAuthentication',
    ),
    'DEFAULT_PERMISSION_CLASSES': (
        'rest_framework.permissions.IsAuthenticatedOrReadOnly',
    ),
    'DEFAULT_PAGINATION_CLASS': 'rest_framework.pagination.PageNumberPagination',
    'PAGE_SIZE': 20,
}

from datetime import timedelta
SIMPLE_JWT = {
    'ACCESS_TOKEN_LIFETIME': timedelta(days=1),
    'REFRESH_TOKEN_LIFETIME': timedelta(days=30),
    'ROTATE_REFRESH_TOKENS': True,
}

# ── CORS (allow iOS app and web frontend) ──────────────────────────────────────
CORS_ALLOWED_ORIGINS = env.list('CORS_ALLOWED_ORIGINS', default=[
    'http://localhost:3000',
    'http://127.0.0.1:3000',
])
# Allow all origins in debug mode (development only)
CORS_ALLOW_ALL_ORIGINS = DEBUG

# ── App Check (verifies /api/ requests come from a real build of the app) ──────
# Set to the numeric Firebase project number (Project Settings → General) once
# a Firebase project is linked. Enforcement turns on automatically when set —
# see config/app_check.py. Empty by default so local dev/CI need no Firebase
# project.
FIREBASE_APP_CHECK_PROJECT_NUMBER = env('FIREBASE_APP_CHECK_PROJECT_NUMBER', default='')
APP_CHECK_ENFORCED = bool(FIREBASE_APP_CHECK_PROJECT_NUMBER)

# ── Firebase Auth (verifies Firebase ID tokens on protected endpoints) ───────────
# Set FIREBASE_AUTH_PROJECT_ID to enable verification. When set, the /api/
# booking endpoint expects an X-Firebase-ID-Token header and validates the
# token's phone_number claim against customer_phone. Empty by default so
# local dev/CI need no Firebase project.
FIREBASE_AUTH_PROJECT_ID = env('FIREBASE_AUTH_PROJECT_ID', default='')
FIREBASE_AUTH_ENFORCED = bool(FIREBASE_AUTH_PROJECT_ID)

GS_QUERYSTRING_AUTH = False


# ── Logging ────────────────────────────────────────────────────────────────────
# Django's default logging only mails ADMINS on unhandled exceptions (no-op
# since ADMINS is unset). Send them to console too so Cloud Run captures
# tracebacks in stderr logs.
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'handlers': {
        'console': {'class': 'logging.StreamHandler'},
    },
    'loggers': {
        'django.request': {
            'handlers': ['console'],
            'level': 'ERROR',
            'propagate': False,
        },
    },
}

# ── Groq Chatbot Settings ──────────────────────────────────────────────────────
GROQ_API_KEY = env('GROQ_API_KEY', default='')
GROQ_MODEL = env('GROQ_MODEL', default='llama-3.3-70b-versatile')