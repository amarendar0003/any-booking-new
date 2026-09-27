import json
import sys

from django.conf import settings
from django.utils import timezone
from rest_framework import generics, status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework_simplejwt.tokens import RefreshToken

from django.contrib.auth import authenticate
from django.db.models import Count, Q, F, DecimalField, ExpressionWrapper
from django.db.models.functions import Coalesce

from services.models import Service, Category, City, Country, State
from services.views import match_location
from bookings.models import Booking
from bookings.emails import send_booking_received
from analytics.models import UsageEvent
from config.firebase_auth import verify_firebase_id_token

from .serializers import (
    CategorySerializer, CitySerializer, CountrySerializer, StateSerializer,
    ServiceListSerializer, ServiceDetailSerializer,
    BookingCreateSerializer, BookingDetailSerializer,
    CancellationRequestSerializer,
)


# ── Auth ──────────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([AllowAny])
def vendor_login(request):
    """
    POST /api/auth/vendor/login/
    Body: { "username": "...", "password": "..." }
    Returns JWT access + refresh tokens and basic vendor info.
    """
    username = request.data.get('username', '').strip()
    password = request.data.get('password', '')

    if not username or not password:
        return Response(
            {'detail': 'Username and password required.'},
            status=status.HTTP_400_BAD_REQUEST,
        )

    user = authenticate(request, username=username, password=password)
    if user is None:
        return Response(
            {'detail': 'Invalid credentials.'},
            status=status.HTTP_401_UNAUTHORIZED,
        )

    # Only allow users that have a vendor profile
    if not hasattr(user, 'vendor_profile'):
        return Response(
            {'detail': 'No vendor account associated with these credentials.'},
            status=status.HTTP_403_FORBIDDEN,
        )

    refresh = RefreshToken.for_user(user)
    vendor = user.vendor_profile
    return Response({
        'access': str(refresh.access_token),
        'refresh': str(refresh),
        'vendor': {
            'id': vendor.id,
            'name': vendor.name,
            'email': vendor.email,
            'phone': vendor.phone,
        },
    })


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def token_refresh_view(request):
    """Convenience endpoint — clients can also use simplejwt's built-in /api/auth/refresh/."""
    from rest_framework_simplejwt.views import TokenRefreshView
    return TokenRefreshView.as_view()(request._request)


# ── Categories ────────────────────────────────────────────────────────────────

class CategoryListView(generics.ListAPIView):
    """GET /api/categories/ — all categories.

    Optional ?country=<id>&state=<id> narrows listing_count to that location.
    """
    serializer_class = CategorySerializer
    permission_classes = [AllowAny]

    def get_queryset(self):
        listing_filter = Q(services__is_active=True)
        state_id = self.request.query_params.get('state')
        country_id = self.request.query_params.get('country')
        if state_id:
            listing_filter &= Q(services__city__district__state_id=state_id)
        elif country_id:
            listing_filter &= Q(services__city__district__state__country_id=country_id)
        return Category.objects.annotate(
            listing_count=Count('services', filter=listing_filter)
        ).order_by('slug')


# ── Locations ────────────────────────────────────────────────────────────────

class CountryListView(generics.ListAPIView):
    """GET /api/countries/ — all active countries."""
    serializer_class = CountrySerializer
    permission_classes = [AllowAny]
    queryset = Country.objects.filter(is_active=True).order_by('name')


class StateListView(generics.ListAPIView):
    """GET /api/states/?country=<id> — states for a country."""
    serializer_class = StateSerializer
    permission_classes = [AllowAny]

    def get_queryset(self):
        qs = State.objects.filter(is_active=True).select_related('country').order_by('name')
        country_id = self.request.query_params.get('country')
        if country_id:
            qs = qs.filter(country_id=country_id)
        return qs


@api_view(['GET'])
@permission_classes([AllowAny])
def location_match(request):
    """
    GET /api/locations/match/?country_code=IN&state_name=Telangana
    Maps a detected ISO country code / state name to our Country and State ids.
    Every field is null when nothing matches.
    """
    return Response(match_location(
        request.query_params.get('country_code', ''),
        request.query_params.get('state_name', ''),
    ))


# ── Cities ────────────────────────────────────────────────────────────────────

class CityListView(generics.ListAPIView):
    """GET /api/cities/ — all active cities."""
    serializer_class = CitySerializer
    permission_classes = [AllowAny]
    queryset = City.objects.filter(is_active=True).select_related(
        'district__state__country'
    ).order_by('name')


class FeaturedCityListView(generics.ListAPIView):
    """GET /api/cities/featured/ — featured cities for homepage."""
    serializer_class = CitySerializer
    permission_classes = [AllowAny]
    queryset = City.objects.filter(is_featured=True, is_active=True).select_related(
        'district__state__country'
    )


# ── Services ─────────────────────────────────────────────────────────────────

class ServiceListView(generics.ListAPIView):
    """
    GET /api/services/
    Query params:
      - category: category slug
      - city: city id
      - country: country id
      - state: state id
      - parking: 1 to filter services with parking available
      - search: text search
      - featured: 1 to filter featured only
      - ordering: price_asc | price_desc | rating
    """
    serializer_class = ServiceListSerializer
    permission_classes = [AllowAny]

    def get_queryset(self):
        qs = Service.objects.filter(is_active=True).select_related(
            'category', 'city', 'vendor'
        ).prefetch_related('images', 'reviews')

        category = self.request.query_params.get('category')
        if category:
            qs = qs.filter(category__slug=category)

        city_id = self.request.query_params.get('city')
        if city_id:
            qs = qs.filter(city_id=city_id)

        country_id = self.request.query_params.get('country')
        if country_id:
            qs = qs.filter(city__district__state__country_id=country_id)

        state_id = self.request.query_params.get('state')
        if state_id:
            qs = qs.filter(city__district__state_id=state_id)

        if self.request.query_params.get('parking') == '1':
            qs = qs.filter(
                attribute_values__attribute__slug='parking-available',
                attribute_values__value_boolean=True,
            )

        search = self.request.query_params.get('search')
        if search:
            qs = qs.filter(
                Q(name__icontains=search) |
                Q(description__icontains=search) |
                Q(city__name__icontains=search) |
                Q(vendor__name__icontains=search)
            )

        if self.request.query_params.get('featured') == '1':
            qs = qs.filter(is_featured=True)

        qs = qs.annotate(
            _effective_price=Coalesce('our_price', 'base_price'),
        ).annotate(
            _final_price=ExpressionWrapper(
                F('_effective_price') * (1 - F('discount_percent') / 100),
                output_field=DecimalField(max_digits=12, decimal_places=2),
            )
        )

        ordering = self.request.query_params.get('ordering', 'featured')
        if ordering == 'price_asc':
            qs = qs.order_by('_final_price')
        elif ordering == 'price_desc':
            qs = qs.order_by('-_final_price')
        else:
            qs = qs.order_by('-is_featured', '-created_at')

        return qs.distinct()


class ServiceDetailView(generics.RetrieveAPIView):
    """GET /api/services/<slug>/"""
    serializer_class = ServiceDetailSerializer
    permission_classes = [AllowAny]
    queryset = Service.objects.filter(is_active=True).select_related(
        'category', 'city__district__state__country', 'vendor'
    ).prefetch_related('images', 'attribute_values__attribute', 'reviews', 'blocked_dates')
    lookup_field = 'slug'

    def retrieve(self, request, *args, **kwargs):
        instance = self.get_object()
        Service.objects.filter(pk=instance.pk).update(view_count=F('view_count') + 1)
        serializer = self.get_serializer(instance)
        return Response(serializer.data)


# ── Bookings ─────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([AllowAny])
def booking_create(request):
    """
    POST /api/bookings/
    Creates a booking. No auth required (public customers).

    When FIREBASE_AUTH_ENFORCED is True, the client must send an
    X-Firebase-ID-Token header containing a Firebase ID token from the
    Flutter app's phone OTP flow. The phone_number claim in that token must
    match the submitted customer_phone.
    """
    if settings.FIREBASE_AUTH_ENFORCED:
        id_token = request.headers.get('X-Firebase-ID-Token')
        if not id_token:
            return Response(
                {'detail': 'Missing Firebase ID token.'},
                status=status.HTTP_401_UNAUTHORIZED,
            )
        try:
            claims = verify_firebase_id_token(id_token)
        except Exception as exc:
            return Response(
                {'detail': f'Invalid Firebase ID token: {exc}'},
                status=status.HTTP_401_UNAUTHORIZED,
            )

    serializer = BookingCreateSerializer(data=request.data)
    if serializer.is_valid():
        booking = serializer.save()
        if settings.FIREBASE_AUTH_ENFORCED:
            token_phone = (claims.get('phone_number') or '').replace(' ', '')
            submitted_phone = (booking.customer_phone or '').replace(' ', '')
            if not token_phone or token_phone != submitted_phone:
                booking.delete()
                return Response(
                    {'customer_phone': 'Phone number does not match verified Firebase account.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )
        try:
            send_booking_received(booking)
        except Exception:
            pass
        return Response(
            BookingDetailSerializer(booking).data,
            status=status.HTTP_201_CREATED,
        )
    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


@api_view(['GET'])
@permission_classes([AllowAny])
def booking_lookup(request):
    """
    GET /api/bookings/lookup/?confirmation_number=AB-XXXXXXXX
    GET /api/bookings/lookup/?name=John&phone=9876543210
    """
    conf = request.query_params.get('confirmation_number', '').strip().upper()
    name = request.query_params.get('name', '').strip()
    phone = request.query_params.get('phone', '').strip()

    booking = None
    if conf:
        booking = Booking.objects.filter(confirmation_number=conf).first()
    elif name and phone:
        booking = Booking.objects.filter(
            customer_name__icontains=name,
            customer_phone__icontains=phone,
        ).order_by('-created_at').first()

    if not booking:
        return Response({'detail': 'Booking not found.'}, status=status.HTTP_404_NOT_FOUND)

    return Response(BookingDetailSerializer(booking).data)


@api_view(['POST'])
@permission_classes([AllowAny])
def booking_cancel_request(request, confirmation_number):
    """
    POST /api/bookings/<confirmation_number>/cancel-request/
    Body: { "reason": "..." }
    """
    booking = Booking.objects.filter(confirmation_number=confirmation_number.upper()).first()
    if not booking:
        return Response({'detail': 'Booking not found.'}, status=status.HTTP_404_NOT_FOUND)

    if booking.status not in ('pending', 'confirmed'):
        return Response(
            {'detail': 'Cancellation requests can only be made for pending or confirmed bookings.'},
            status=status.HTTP_400_BAD_REQUEST,
        )

    if booking.cancellation_requested:
        return Response(
            {'detail': 'A cancellation request has already been submitted.'},
            status=status.HTTP_400_BAD_REQUEST,
        )

    serializer = CancellationRequestSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    booking.cancellation_requested = True
    booking.cancellation_request_reason = serializer.validated_data['reason']
    booking.cancellation_requested_at = timezone.now()
    booking.save(update_fields=[
        'cancellation_requested',
        'cancellation_request_reason',
        'cancellation_requested_at',
    ])

    return Response({'detail': 'Cancellation request submitted successfully.'})


# ── Client error reporting ──────────────────────────────────────────────────────

_ALLOWED_CLIENT_ERROR_SEVERITIES = {'ERROR', 'WARNING'}


@api_view(['POST'])
@permission_classes([AllowAny])
def report_client_error(request):
    """
    POST /api/client-errors/
    Body: { "message": "...", "stack": "...", "severity": "ERROR", "platform": "ios",
            "route": "/services", "appVersion": "1.0.0 (18)" }

    Lets the Flutter app (web/Android/iOS) report otherwise-invisible client
    failures — uncaught exceptions, failed API calls — to the same place the
    backend's own logs live, since crashes on a user's device are otherwise
    only visible via app-store crash reporters (TestFlight) or not at all.
    Writes a single JSON line to stdout in Cloud Run's structured logging
    format (https://cloud.google.com/run/docs/logging#run_manual_logging) so
    it shows up in Cloud Logging with the right severity and is queryable on
    the extra fields, instead of a flat unstructured text log.
    """
    data = request.data if isinstance(request.data, dict) else {}
    severity = str(data.get('severity', 'ERROR')).upper()
    if severity not in _ALLOWED_CLIENT_ERROR_SEVERITIES:
        severity = 'ERROR'

    entry = {
        'severity': severity,
        'message': str(data.get('message', 'Unspecified client error'))[:2000],
        'logName': 'client-error',
        'platform': str(data.get('platform', 'unknown'))[:40],
        'appVersion': str(data.get('appVersion', ''))[:60],
        'route': str(data.get('route', ''))[:200],
        'stack': str(data.get('stack', ''))[:4000],
        'userAgent': request.META.get('HTTP_USER_AGENT', '')[:300],
    }
    print(json.dumps(entry), file=sys.stdout, flush=True)
    return Response(status=status.HTTP_204_NO_CONTENT)


# ── Usage analytics ──────────────────────────────────────────────────────────

_VALID_PLATFORMS = {
    UsageEvent.PLATFORM_WEB,
    UsageEvent.PLATFORM_ANDROID,
    UsageEvent.PLATFORM_IOS,
}


@api_view(['POST'])
@permission_classes([AllowAny])
def report_usage_event(request):
    """
    POST /api/usage-events/
    Body: { "deviceId": "...", "platform": "ios", "appVersion": "1.0.0 (18)",
            "eventType": "app_open", "route": "/" }

    Records a single anonymous usage event for the admin dashboard's usage
    section. deviceId is a UUID the client generates once and persists
    locally — this endpoint doesn't and can't verify it, it's purely a
    self-reported anonymous install identifier, not a hardware device ID.
    """
    data = request.data if isinstance(request.data, dict) else {}
    device_id = str(data.get('deviceId', ''))[:64]
    if not device_id:
        return Response(
            {'detail': 'deviceId is required.'}, status=status.HTTP_400_BAD_REQUEST
        )

    platform = str(data.get('platform', '')).lower()
    if platform not in _VALID_PLATFORMS:
        platform = UsageEvent.PLATFORM_OTHER

    UsageEvent.objects.create(
        device_id=device_id,
        platform=platform,
        app_version=str(data.get('appVersion', ''))[:40],
        event_type=str(data.get('eventType', UsageEvent.EVENT_APP_OPEN))[:30],
        route=str(data.get('route', ''))[:200],
    )
    return Response(status=status.HTTP_204_NO_CONTENT)


# ── Vendor ────────────────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([IsAuthenticated])
def vendor_dashboard(request):
    """
    GET /api/vendor/dashboard/
    Returns summary stats and recent bookings for authenticated vendor.
    """
    user = request.user
    if not hasattr(user, 'vendor_profile'):
        return Response({'detail': 'Not a vendor account.'}, status=status.HTTP_403_FORBIDDEN)

    vendor = user.vendor_profile
    services = vendor.services.filter(is_active=True)
    service_ids = services.values_list('id', flat=True)
    bookings = Booking.objects.filter(service_id__in=service_ids).order_by('-created_at')

    recent = bookings[:10]

    return Response({
        'vendor': {
            'id': vendor.id,
            'name': vendor.name,
            'email': vendor.email,
            'phone': vendor.phone,
        },
        'stats': {
            'active_listings': services.count(),
            'pending': bookings.filter(status='pending').count(),
            'confirmed': bookings.filter(status='confirmed').count(),
            'completed': bookings.filter(status='completed').count(),
        },
        'recent_bookings': BookingDetailSerializer(recent, many=True).data,
    })


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def vendor_bookings(request):
    """
    GET /api/vendor/bookings/?status=pending
    Returns paginated bookings for authenticated vendor.
    """
    user = request.user
    if not hasattr(user, 'vendor_profile'):
        return Response({'detail': 'Not a vendor account.'}, status=status.HTTP_403_FORBIDDEN)

    vendor = user.vendor_profile
    service_ids = vendor.services.values_list('id', flat=True)
    bookings = Booking.objects.filter(service_id__in=service_ids).order_by('-created_at')

    booking_status = request.query_params.get('status')
    if booking_status:
        bookings = bookings.filter(status=booking_status)

    return Response(BookingDetailSerializer(bookings, many=True).data)
