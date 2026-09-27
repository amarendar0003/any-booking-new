import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://any-booking-392995898519.us-central1.run.app/api',
);
final normalizedApiBaseUrl = apiBaseUrl.endsWith('/')
    ? apiBaseUrl.substring(0, apiBaseUrl.length - 1)
    : apiBaseUrl;

// reCAPTCHA v3 site key for App Check on web. Leave unset to skip web
// attestation (Android/iOS attestation works independently of this).
const _appCheckWebRecaptchaSiteKey = String.fromEnvironment(
  'APP_CHECK_WEB_RECAPTCHA_SITE_KEY',
  defaultValue: '',
);

Future<void> main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        reportClientError(
          message: details.exceptionAsString(),
          stack: details.stack?.toString(),
        );
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        reportClientError(message: error.toString(), stack: stack.toString());
        return true;
      };
      await _initAppCheck();
      runApp(const AnyBookingApp());
      unawaited(_reportAppOpen());
    },
    (error, stack) =>
        reportClientError(message: error.toString(), stack: stack.toString()),
  );
}

/// Records one anonymous app-open event per launch for the admin dashboard's
/// usage-by-platform section (see backend/api/views.py:report_usage_event).
/// deviceId is a random ID generated once and persisted locally — it's an
/// anonymous per-install identifier, not a real hardware device ID.
Future<void> _reportAppOpen() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString('device_id');
    if (deviceId == null) {
      final random = Random.secure();
      deviceId = List.generate(
        32,
        (_) => random.nextInt(16).toRadixString(16),
      ).join();
      await prefs.setString('device_id', deviceId);
    }
    await BookingApi().reportUsage(deviceId: deviceId);
  } catch (_) {
    // Usage reporting must never affect the app itself.
  }
}

/// Best-effort fire-and-forget report of a client-side failure to
/// POST /api/client-errors/, so crashes and failed API calls on a user's
/// device show up in Cloud Logging instead of being invisible unless someone
/// happens to be looking at a TestFlight/Play Console crash report. Never
/// awaited by callers and never throws — a reporting failure must not affect
/// the app itself.
void reportClientError({required String message, String? stack}) {
  unawaited(
    BookingApi().reportError(message: message, stack: stack).catchError((
          _,
        ) {}),
  );
}

/// Activates Firebase App Check so the backend can verify requests come from
/// a genuine build of this app (see backend/config/app_check.py). Debug
/// providers are used in debug builds since Play Integrity / App Attest
/// don't work on emulators/simulators or unregistered dev devices.
///
/// `lib/firebase_options.dart` ships with placeholder values until
/// `flutterfire configure` is run against a real Firebase project. Passing
/// those to `Firebase.initializeApp()` doesn't fail gracefully — the native
/// SDK rejects a malformed App ID with an uncatchable NSException (fatal
/// SIGABRT) rather than a Dart-catchable error, so this bails out before
/// ever calling it instead of relying on the try/catch below to save it.
/// True once `flutterfire configure` has replaced the placeholder values in
/// firebase_options.dart with a real Firebase project's config.
bool get firebaseConfigured =>
    DefaultFirebaseOptions.currentPlatform.apiKey !=
    'REPLACE_WITH_FLUTTERFIRE_CONFIGURE';

Future<void> _initAppCheck() async {
  if (!firebaseConfigured) {
    debugPrint('App Check not initialized (using placeholder config?)');
    return;
  }
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await FirebaseAppCheck.instance.activate(
      // ignore: deprecated_member_use
      androidProvider:
          kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
      // ignore: deprecated_member_use
      appleProvider: kDebugMode ? AppleProvider.debug : AppleProvider.appAttest,
      // ignore: deprecated_member_use
      webProvider: kIsWeb && _appCheckWebRecaptchaSiteKey.isNotEmpty
          ? ReCaptchaV3Provider(_appCheckWebRecaptchaSiteKey)
          : null,
    );
  } catch (error) {
    debugPrint('App Check not initialized (using placeholder config?): $error');
  }
}

Future<String?> _appCheckToken() async {
  try {
    return await FirebaseAppCheck.instance.getToken();
  } catch (_) {
    return null;
  }
}

class AnyBookingApp extends StatelessWidget {
  const AnyBookingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AnyBooking',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _brandPrimary).copyWith(
          primary: _brandPrimary,
          onPrimary: Colors.white,
          onSurface: _brandText,
        ),
        scaffoldBackgroundColor: const Color(0xfffffaf5),
        useMaterial3: true,
        fontFamily: 'sans',
        appBarTheme: const AppBarTheme(
          backgroundColor: _brandSurface,
          surfaceTintColor: Colors.transparent,
          foregroundColor: _brandText,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: _brandBorder),
          ),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: _brandSurface,
          indicatorColor: Color(0xffffedd5),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _brandBorder),
          ),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int selectedIndex = 0;
  String? selectedCategory;
  String searchQuery = '';
  LocationPref? location;
  List<CategoryInfo> categories = CategoryInfo.fallback;
  final api = BookingApi();

  @override
  void initState() {
    super.initState();
    LocationPref.load().then((saved) {
      if (!mounted) return;
      setState(() => location = saved);
      _loadCategories();
      // Like the Django site, ask on first visit; dismissing just skips it.
      if (saved == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _chooseLocation();
        });
      }
    });
  }

  Future<void> _chooseLocation() async {
    final result = await showLocationDialog(context, api, location);
    if (result == null || !mounted) return;
    await LocationPref.save(result.pref);
    if (mounted) setState(() => location = result.pref);
    _loadCategories();
  }

  void _loadCategories() {
    api.categories(location: location).then((value) {
      if (mounted && value.isNotEmpty) setState(() => categories = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final nav = NavActions(
      onHome: () => setState(() => selectedIndex = 0),
      onBrowseServices: () => setState(() => selectedIndex = 1),
      onCategorySelected: (category) => setState(() {
        selectedCategory = category;
        searchQuery = '';
        selectedIndex = 1;
      }),
      onFindBooking: () => setState(() => selectedIndex = 2),
      onChangeLocation: _chooseLocation,
      location: location,
    );
    final pages = [
      HomePage(
        api: api,
        nav: nav,
        categories: categories,
        onSearch: (query) => setState(() {
          selectedCategory = null;
          searchQuery = query;
          selectedIndex = 1;
        }),
      ),
      ServicesPage(
        key: ValueKey(
          '$selectedCategory|$searchQuery|${location?.countryId}|${location?.stateId}',
        ),
        api: api,
        nav: nav,
        categories: categories,
        initialCategory: selectedCategory,
        initialQuery: searchQuery,
        location: location,
      ),
      BookingLookupPage(nav: nav, categories: categories),
      const VendorPage(),
    ];
    return Scaffold(
      body: IndexedStack(index: selectedIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) => setState(() => selectedIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.view_list_outlined),
            selectedIcon: Icon(Icons.view_list),
            label: 'Services',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'My Booking',
          ),
          NavigationDestination(
            icon: Icon(Icons.storefront_outlined),
            selectedIcon: Icon(Icons.storefront),
            label: 'Vendor',
          ),
        ],
      ),
    );
  }
}

class Country {
  const Country({required this.id, required this.name});
  final int id;
  final String name;

  factory Country.fromJson(Map<String, dynamic> json) =>
      Country(id: json['id'] as int, name: json['name'] as String? ?? '');
}

class StateOption {
  const StateOption({required this.id, required this.name});
  final int id;
  final String name;

  factory StateOption.fromJson(Map<String, dynamic> json) =>
      StateOption(id: json['id'] as int, name: json['name'] as String? ?? '');
}

class BookingApi {
  static String? categorySlug(String? categoryName) => const {
        'Banquet Hall': 'banquet_hall',
        'Music Band': 'music_band',
        'Event Management': 'event_management',
        'Catering': 'catering',
        'Dance Instructor': 'dancing',
        'Dancing': 'dancing',
        'Priests': 'priests',
        'Hotels': 'hotels',
      }[categoryName];

  Future<Map<String, String>> _headers([Map<String, String>? extra]) async {
    final token = await _appCheckToken();
    return {if (token != null) 'X-Firebase-AppCheck': token, ...?extra};
  }

  /// Detects the caller's country/state from their IP (same ipapi.co lookup
  /// the Django site uses) and maps it onto our own location ids.
  /// Returns null when detection fails or the region isn't in our database.
  Future<LocationPref?> detectLocation() async {
    try {
      final geoResponse = await http.get(Uri.parse('https://ipapi.co/json/'));
      if (geoResponse.statusCode != 200) return null;
      final geo = jsonDecode(geoResponse.body) as Map<String, dynamic>;
      final countryCode = geo['country_code'] as String? ?? '';
      if (countryCode.isEmpty) return null;
      final matchResponse = await http.get(
        Uri.parse('$normalizedApiBaseUrl/locations/match/').replace(
          queryParameters: {
            'country_code': countryCode,
            'state_name': geo['region'] as String? ?? '',
          },
        ),
        headers: await _headers(),
      );
      if (matchResponse.statusCode != 200) return null;
      final match = jsonDecode(matchResponse.body) as Map<String, dynamic>;
      final countryId = match['country_id'] as int?;
      if (countryId == null) return null;
      return LocationPref(
        countryId: countryId,
        countryName: match['country_name'] as String? ?? '',
        stateId: match['state_id'] as int?,
        stateName: match['state_name'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<CategoryInfo>> categories({LocationPref? location}) async {
    try {
      final response = await http.get(
        Uri.parse('$normalizedApiBaseUrl/categories/').replace(
          queryParameters: {
            if (location != null) 'country': '${location.countryId}',
            if (location?.stateId != null) 'state': '${location!.stateId}',
          },
        ),
        headers: await _headers(),
      );
      if (response.statusCode != 200) return [];
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return (json['results'] as List<dynamic>? ?? [])
          .map((item) => CategoryInfo.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Country>> countries() async {
    try {
      final response = await http.get(
        Uri.parse('$normalizedApiBaseUrl/countries/'),
        headers: await _headers(),
      );
      if (response.statusCode != 200) return [];
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return (json['results'] as List<dynamic>? ?? [])
          .map((item) => Country.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<StateOption>> states(int countryId) async {
    try {
      final response = await http.get(
        Uri.parse(
          '$normalizedApiBaseUrl/states/',
        ).replace(queryParameters: {'country': '$countryId'}),
        headers: await _headers(),
      );
      if (response.statusCode != 200) return [];
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return (json['results'] as List<dynamic>? ?? [])
          .map((item) => StateOption.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static String get _platformName {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform.name;
  }

  /// POSTs a client-side failure to Cloud Logging via the backend (see
  /// backend/api/views.py:report_client_error). Deliberately doesn't use
  /// _headers()/App Check — this must still work when Firebase itself is
  /// what failed, and it's a fire-and-forget diagnostic call, not something
  /// that needs the same trust boundary as real API calls.
  Future<void> reportError({
    required String message,
    String? stack,
    String severity = 'ERROR',
    String route = '',
  }) async {
    try {
      await http
          .post(
            Uri.parse('$normalizedApiBaseUrl/client-errors/'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'message': message,
              'stack': stack ?? '',
              'severity': severity,
              'platform': _platformName,
              'route': route,
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Reporting the error must never itself throw or block the app.
    }
  }

  /// See _reportAppOpen() — posts to /api/usage-events/ for the admin
  /// dashboard's usage-by-platform section. Fire-and-forget by design.
  Future<void> reportUsage({
    required String deviceId,
    String eventType = 'app_open',
    String route = '',
  }) async {
    try {
      await http
          .post(
            Uri.parse('$normalizedApiBaseUrl/usage-events/'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'deviceId': deviceId,
              'platform': _platformName,
              'eventType': eventType,
              'route': route,
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Reporting usage must never itself throw or block the app.
    }
  }

  Future<List<Service>> services({
    String? category,
    int? countryId,
    int? stateId,
    bool parkingOnly = false,
  }) async {
    final loadedServices = <Service>[];
    Uri? nextUri = Uri.parse('$normalizedApiBaseUrl/services/').replace(
      queryParameters: {
        if (category != null) 'category': category,
        if (countryId != null) 'country': '$countryId',
        if (stateId != null) 'state': '$stateId',
        if (parkingOnly) 'parking': '1',
      },
    );
    final headers = await _headers();

    var isFirstPage = true;
    while (nextUri != null) {
      final response = await http.get(nextUri, headers: headers);
      if (response.statusCode != 200) {
        if (isFirstPage) {
          throw Exception(
            'Services request failed: HTTP ${response.statusCode}',
          );
        }
        break;
      }
      isFirstPage = false;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      loadedServices.addAll(
        (json['results'] as List<dynamic>? ?? [])
            .map((item) => Service.fromJson(item as Map<String, dynamic>)),
      );
      final next = json['next'] as String?;
      nextUri = next == null ? null : Uri.parse(next);
    }
    return loadedServices;
  }

  Future<List<Service>> featuredServices() async {
    try {
      final response = await http.get(
        Uri.parse('$normalizedApiBaseUrl/services/?featured=1'),
        headers: await _headers(),
      );
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final results = (json['results'] as List<dynamic>? ?? []);
        final featured = results
            .map((item) => Service.fromJson(item as Map<String, dynamic>))
            .toList();
        if (featured.isNotEmpty) return featured;

        return await services();
      }
    } catch (_) {}
    return Service.samples;
  }

  Future<ServiceDetail?> serviceDetail(String slug) async {
    try {
      final response = await http.get(
        Uri.parse('$normalizedApiBaseUrl/services/$slug/'),
        headers: await _headers(),
      );
      if (response.statusCode != 200) return null;
      return ServiceDetail.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// Returns null on success, otherwise a message to show the user.
  Future<String?> requestCancellation(
    String confirmationNumber,
    String reason,
  ) async {
    try {
      final response = await http.post(
        Uri.parse(
          '$normalizedApiBaseUrl/bookings/${Uri.encodeComponent(confirmationNumber)}/cancel-request/',
        ),
        headers: await _headers({'Content-Type': 'application/json'}),
        body: jsonEncode({'reason': reason}),
      );
      if (response.statusCode == 200) return null;
      final body = jsonDecode(response.body);
      if (body is Map) {
        final detail = body['detail'] ?? body['reason'];
        if (detail != null) {
          return detail is List ? detail.join(' ') : detail.toString();
        }
      }
      return 'Could not submit the cancellation request.';
    } catch (_) {
      return 'Unable to reach the booking service right now.';
    }
  }

  Future<BookingResult> lookupBooking({
    String confirmationNumber = '',
    String lastName = '',
    String phone = '',
  }) async {
    try {
      final response = await http.get(
        Uri.parse('$normalizedApiBaseUrl/bookings/lookup/').replace(
          queryParameters: {
            if (confirmationNumber.isNotEmpty)
              'confirmation_number': confirmationNumber
            else ...{'name': lastName, 'phone': phone},
          },
        ),
        headers: await _headers(),
      );
      if (response.statusCode == 200) {
        return BookingResult.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>,
        );
      }
      return BookingResult.error(
        'No booking found. Check the confirmation number, or your last name and phone number, and try again.',
      );
    } catch (_) {
      return BookingResult.error(
        'Unable to reach the booking service right now.',
      );
    }
  }

  Future<BookingResult> createBooking({
    required String serviceSlug,
    required String customerName,
    required String customerEmail,
    required String customerPhone,
    required DateTime eventDate,
    required int guestCount,
    required double totalAmount,
    String specialRequests = '',
    String? firebaseIdToken,
  }) async {
    try {
      final extra = <String, String>{
        'Content-Type': 'application/json',
        if (firebaseIdToken != null && firebaseIdToken.isNotEmpty)
          'X-Firebase-ID-Token': firebaseIdToken,
      };
      final response = await http.post(
        Uri.parse('$normalizedApiBaseUrl/bookings/'),
        headers: await _headers(extra),
        body: jsonEncode({
          'service_slug': serviceSlug,
          'customer_name': customerName,
          'customer_email': customerEmail,
          'customer_phone': customerPhone,
          'event_date': '${eventDate.year.toString().padLeft(4, '0')}-'
              '${eventDate.month.toString().padLeft(2, '0')}-'
              '${eventDate.day.toString().padLeft(2, '0')}',
          'guest_count': guestCount,
          'special_requests': specialRequests,
          'total_amount': totalAmount.toStringAsFixed(2),
          'terms_accepted': true,
        }),
      );
      if (response.statusCode == 201) {
        return BookingResult.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>,
        );
      }
      final body = jsonDecode(response.body);
      if (body is Map) {
        final message = body.entries
            .map(
              (e) => e.value is List
                  ? (e.value as List).join(', ')
                  : e.value.toString(),
            )
            .join(' ');
        if (message.trim().isNotEmpty) return BookingResult.error(message);
      }
      return BookingResult.error('Could not create the booking.');
    } catch (_) {
      return BookingResult.error(
        'Unable to reach the booking service right now.',
      );
    }
  }

  Future<bool> vendorLogin(String username, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$normalizedApiBaseUrl/auth/vendor/login/'),
        headers: await _headers({'Content-Type': 'application/json'}),
        body: jsonEncode({'username': username, 'password': password}),
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }
}

class ServiceOffering {
  const ServiceOffering({required this.name, required this.displayValue});

  final String name;
  final String displayValue;

  factory ServiceOffering.fromJson(Map<String, dynamic> json) =>
      ServiceOffering(
        name: json['name'] as String? ?? '',
        displayValue: json['display_value'] as String? ?? '',
      );
}

String _formatAmount(double amount) {
  final whole = amount.round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buf.write(',');
    buf.write(whole[i]);
  }
  return buf.toString();
}

double _parseAmount(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

class Service {
  const Service({
    required this.name,
    required this.category,
    required this.city,
    required this.priceValue,
    required this.rating,
    this.slug = '',
    this.originalPriceValue,
    this.discountPercent = 0,
    this.priceUnit = '',
    this.offerings = const [],
    this.cancellationPolicy = '',
    this.imageUrl,
    this.isFeatured = false,
    this.vendorName = '',
    this.reviewCount = 0,
  });

  final String name;
  final String category;
  final String city;
  final double priceValue;
  final double rating;
  final String slug;
  final double? originalPriceValue;
  final double discountPercent;
  final String priceUnit;
  final List<ServiceOffering> offerings;
  final String cancellationPolicy;
  final String? imageUrl;
  final bool isFeatured;
  final String vendorName;
  final int reviewCount;

  String get price =>
      '₹${_formatAmount(priceValue)}${priceUnit.isEmpty ? '' : ' $priceUnit'}';

  String? get originalPriceLabel =>
      (originalPriceValue == null || discountPercent <= 0)
          ? null
          : '₹${_formatAmount(originalPriceValue!)}';

  factory Service.fromJson(Map<String, dynamic> json) => Service(
        name: json['name'] as String? ?? 'Unnamed service',
        category: json['categoryName'] as String? ??
            json['category_name'] as String? ??
            'Event service',
        city: json['cityName'] as String? ??
            json['city_name'] as String? ??
            'India',
        priceValue: _parseAmount(json['price']),
        originalPriceValue: json['original_price'] != null
            ? _parseAmount(json['original_price'])
            : null,
        discountPercent: _parseAmount(json['discount_percent']),
        priceUnit:
            json['price_unit'] as String? ?? json['priceUnit'] as String? ?? '',
        rating: (json['averageRating'] as num? ??
                json['average_rating'] as num? ??
                0)
            .toDouble(),
        slug: json['slug'] as String? ?? '',
        offerings: (json['attributes'] as List<dynamic>? ?? [])
            .map((a) => ServiceOffering.fromJson(a as Map<String, dynamic>))
            .toList(),
        cancellationPolicy: json['cancellation_policy'] as String? ??
            json['cancellationPolicy'] as String? ??
            '',
        imageUrl: json['primary_image_url'] as String?,
        isFeatured: json['is_featured'] as bool? ?? false,
        vendorName: json['vendor_name'] as String? ?? '',
        reviewCount: json['review_count'] as int? ?? 0,
      );

  static const samples = [
    Service(
      name: 'Royal Banquet Hall',
      category: 'Banquet Hall',
      city: 'Hyderabad',
      priceValue: 150000,
      rating: 4.7,
    ),
    Service(
      name: 'Harmony Music Band',
      category: 'Music Band',
      city: 'Mumbai',
      priceValue: 50000,
      rating: 4.5,
    ),
    Service(
      name: 'Elite Catering Services',
      category: 'Catering',
      city: 'Delhi',
      priceValue: 800,
      priceUnit: '/ plate',
      rating: 4.8,
    ),
  ];
}

class BookingResult {
  const BookingResult({
    this.confirmationNumber,
    this.serviceName,
    this.status,
    this.error,
    this.id,
    this.customerName,
    this.customerPhone,
    this.eventDate,
    this.guestCount,
    this.totalAmount,
    this.advanceAmount,
    this.cancellationRequested = false,
  });

  final String? confirmationNumber;
  final String? serviceName;
  final String? status;
  final String? error;
  final int? id;
  final String? customerName;
  final String? customerPhone;
  final String? eventDate;
  final int? guestCount;
  final double? totalAmount;
  final double? advanceAmount;
  final bool cancellationRequested;

  bool get isActive => status == 'pending' || status == 'confirmed';

  factory BookingResult.fromJson(Map<String, dynamic> json) => BookingResult(
        confirmationNumber: json['confirmationNumber'] as String? ??
            json['confirmation_number'] as String?,
        serviceName:
            json['serviceName'] as String? ?? json['service_name'] as String?,
        status: json['status'] as String?,
        id: json['id'] as int?,
        customerName: json['customer_name'] as String?,
        customerPhone: json['customer_phone'] as String?,
        eventDate: json['event_date'] as String?,
        guestCount: json['guest_count'] as int?,
        totalAmount: json['total_amount'] == null
            ? null
            : _parseAmount(json['total_amount']),
        advanceAmount: json['advance_amount'] == null
            ? null
            : _parseAmount(json['advance_amount']),
        cancellationRequested: json['cancellation_requested'] as bool? ?? false,
      );

  factory BookingResult.error(String message) => BookingResult(error: message);
}

class ReviewInfo {
  const ReviewInfo({
    required this.name,
    required this.rating,
    required this.body,
    required this.date,
  });
  final String name;
  final int rating;
  final String body;
  final String date;

  factory ReviewInfo.fromJson(Map<String, dynamic> json) => ReviewInfo(
        name: json['reviewer_name'] as String? ?? '',
        rating: json['rating'] as int? ?? 0,
        body: json['body'] as String? ?? '',
        date: (json['created_at'] as String? ?? '').split('T').first,
      );
}

/// Everything the service detail page shows beyond the list summary.
class ServiceDetail {
  const ServiceDetail({
    required this.service,
    required this.imageUrls,
    required this.description,
    required this.locationLine,
    required this.vendorPhone,
    required this.vendorEmail,
    required this.reviews,
    required this.bookedDates,
  });
  final Service service;
  final List<String> imageUrls;
  final String description;
  final String locationLine;
  final String vendorPhone;
  final String vendorEmail;
  final List<ReviewInfo> reviews;
  final Set<String> bookedDates;

  factory ServiceDetail.fromJson(Map<String, dynamic> json) {
    final category = json['category'] as Map<String, dynamic>? ?? {};
    final city = json['city'] as Map<String, dynamic>?;
    final vendor = json['vendor'] as Map<String, dynamic>? ?? {};
    final images = (json['images'] as List<dynamic>? ?? [])
        .map((i) => (i as Map<String, dynamic>)['url'] as String?)
        .whereType<String>()
        .toList();
    final base = Service.fromJson({
      ...json,
      'category_name': category['display_name'],
      'city_name': city?['name'],
      'vendor_name': vendor['name'],
      'primary_image_url': images.isEmpty ? null : images.first,
    });
    return ServiceDetail(
      service: base,
      imageUrls: images,
      description: json['description'] as String? ?? '',
      locationLine: [
        city?['name'],
        city?['state_name'],
      ].whereType<String>().where((v) => v.isNotEmpty).join(', '),
      vendorPhone: vendor['phone'] as String? ?? '',
      vendorEmail: vendor['email'] as String? ?? '',
      reviews: (json['reviews'] as List<dynamic>? ?? [])
          .map((r) => ReviewInfo.fromJson(r as Map<String, dynamic>))
          .toList(),
      bookedDates: (json['booked_dates'] as List<dynamic>? ?? [])
          .map((d) => d as String)
          .toSet(),
    );
  }
}

// Brand palette shared with the Django site (backend/static/css/main.css).
const _brandPrimary = Color(0xfff97316);
const _brandText = Color(0xff431407);
const _brandTextSecondary = Color(0xff7c5a4d);
const _brandBorder = Color(0xfffed7aa);
const _brandSurface = Color(0xfffff7ed);

/// Icon and gradient for a category tile, keyed by category slug.
const _categoryStyles = <String, (IconData, List<Color>)>{
  'banquet_hall': (
    Icons.account_balance,
    [Color(0xff1e3a5f), Color(0xff0369a1)]
  ),
  'music_band': (Icons.music_note, [Color(0xff14532d), Color(0xff166534)]),
  'catering': (Icons.restaurant, [Color(0xff7c2d12), Color(0xff92400e)]),
  'hotels': (Icons.hotel, [Color(0xff1e1b4b), Color(0xff3730a3)]),
  'dancing': (Icons.nightlife, [Color(0xff4c1d95), Color(0xff6d28d9)]),
  'priests': (Icons.self_improvement, [Color(0xff7f1d1d), Color(0xff991b1b)]),
  'event_management': (
    Icons.celebration,
    [Color(0xff064e3b), Color(0xff065f46)]
  ),
};
const _defaultCategoryStyle = (
  Icons.category,
  [Color(0xff0f172a), Color(0xff1e3a5f)],
);

const double _contentMaxWidth = 1200;
const double _wideBreakpoint = 900;

double _gutter(double width) => max(16, (width - _contentMaxWidth) / 2 + 16);

/// The user's saved country/state preference, persisted across launches.
/// Mirrors the Django site's ab_country / ab_state cookies.
class LocationPref {
  const LocationPref({
    required this.countryId,
    required this.countryName,
    this.stateId,
    this.stateName,
  });
  final int countryId;
  final String countryName;
  final int? stateId;
  final String? stateName;

  String get label =>
      stateName == null ? countryName : '$stateName, $countryName';

  static Future<LocationPref?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final countryId = prefs.getInt('loc_country_id');
      if (countryId == null) return null;
      return LocationPref(
        countryId: countryId,
        countryName: prefs.getString('loc_country_name') ?? '',
        stateId: prefs.getInt('loc_state_id'),
        stateName: prefs.getString('loc_state_name'),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(LocationPref? pref) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in const [
        'loc_country_id',
        'loc_country_name',
        'loc_state_id',
        'loc_state_name',
      ]) {
        await prefs.remove(key);
      }
      if (pref == null) return;
      await prefs.setInt('loc_country_id', pref.countryId);
      await prefs.setString('loc_country_name', pref.countryName);
      if (pref.stateId != null) {
        await prefs.setInt('loc_state_id', pref.stateId!);
        await prefs.setString('loc_state_name', pref.stateName ?? '');
      }
    } catch (_) {
      // Losing the saved preference is harmless; the user can pick again.
    }
  }
}

/// Opens the "Where are you looking?" dialog. Returns null if dismissed, or a
/// record whose [pref] is the new choice (null when the user cleared it).
Future<({LocationPref? pref})?> showLocationDialog(
  BuildContext context,
  BookingApi api,
  LocationPref? current,
) =>
    showDialog<({LocationPref? pref})>(
      context: context,
      builder: (_) => _LocationDialog(api: api, current: current),
    );

class _LocationDialog extends StatefulWidget {
  const _LocationDialog({required this.api, required this.current});
  final BookingApi api;
  final LocationPref? current;

  @override
  State<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends State<_LocationDialog> {
  List<Country> countries = [];
  List<StateOption> stateOptions = [];
  int? countryId;
  int? stateId;
  bool detecting = false;
  String status = '';
  bool statusIsError = false;

  @override
  void initState() {
    super.initState();
    countryId = widget.current?.countryId;
    stateId = widget.current?.stateId;
    widget.api.countries().then((value) {
      if (mounted) setState(() => countries = value);
    });
    if (countryId != null) _loadStates(countryId!);
  }

  Future<void> _loadStates(int id) async {
    final loaded = await widget.api.states(id);
    if (mounted && countryId == id) setState(() => stateOptions = loaded);
  }

  Future<void> _detect() async {
    setState(() {
      detecting = true;
      statusIsError = false;
      status = 'Detecting…';
    });
    final found = await widget.api.detectLocation();
    if (!mounted) return;
    if (found == null) {
      setState(() {
        detecting = false;
        statusIsError = true;
        status = "We couldn't match your region — please select manually.";
      });
      return;
    }
    setState(() {
      countryId = found.countryId;
      stateId = found.stateId;
      stateOptions = [];
      detecting = false;
      status = 'Detected: ${found.label}';
    });
    await _loadStates(found.countryId);
  }

  void _confirm() {
    final id = countryId;
    if (id == null) {
      Navigator.of(context).pop((pref: null));
      return;
    }
    final country = countries.where((c) => c.id == id).firstOrNull;
    final state = stateOptions.where((s) => s.id == stateId).firstOrNull;
    Navigator.of(context).pop((
      pref: LocationPref(
        countryId: id,
        countryName: country?.name ?? widget.current?.countryName ?? '',
        stateId: state?.id,
        stateName: state?.name,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: const Color(0xfffffaf5),
        title: const Column(
          children: [
            Icon(Icons.location_on, color: _brandPrimary, size: 36),
            SizedBox(height: 8),
            Text(
              'Where are you looking?',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 4),
            Text(
              "We'll show services available in your area",
              style: TextStyle(fontSize: 13, color: _brandTextSecondary),
            ),
          ],
        ),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: detecting ? null : _detect,
                  icon: const Icon(Icons.my_location, size: 18),
                  label: const Text('Detect my location'),
                ),
                SizedBox(
                  height: 28,
                  child: Center(
                    child: Text(
                      status,
                      style: TextStyle(
                        fontSize: 12,
                        color: statusIsError
                            ? Colors.red.shade700
                            : Colors.green.shade700,
                      ),
                    ),
                  ),
                ),
                const Text(
                  '— or select manually —',
                  style: TextStyle(fontSize: 12, color: _brandTextSecondary),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<int?>(
                  key: ValueKey('country-$countryId-${countries.length}'),
                  initialValue: countries.any((c) => c.id == countryId)
                      ? countryId
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Country'),
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('Select a country…')),
                    ...countries.map(
                      (c) => DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ),
                  ],
                  onChanged: (value) {
                    setState(() {
                      countryId = value;
                      stateId = null;
                      stateOptions = [];
                    });
                    if (value != null) _loadStates(value);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int?>(
                  key: ValueKey(
                      'state-$countryId-$stateId-${stateOptions.length}'),
                  initialValue:
                      stateOptions.any((s) => s.id == stateId) ? stateId : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'State / Region (optional)'),
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('All states')),
                    ...stateOptions.map(
                      (s) => DropdownMenuItem(value: s.id, child: Text(s.name)),
                    ),
                  ],
                  onChanged: countryId == null
                      ? null
                      : (value) => setState(() => stateId = value),
                ),
              ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: _confirm,
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Confirm Location'),
          ),
        ],
      );
}

class CategoryInfo {
  const CategoryInfo({required this.slug, required this.name, this.count});
  final String slug;
  final String name;
  final int? count;

  factory CategoryInfo.fromJson(Map<String, dynamic> json) => CategoryInfo(
        slug: json['slug'] as String? ?? '',
        name: json['display_name'] as String? ?? '',
        count: json['listing_count'] as int?,
      );

  static const fallback = [
    CategoryInfo(slug: 'banquet_hall', name: 'Banquet Hall'),
    CategoryInfo(slug: 'music_band', name: 'Music Band'),
    CategoryInfo(slug: 'catering', name: 'Catering'),
    CategoryInfo(slug: 'hotels', name: 'Hotels'),
    CategoryInfo(slug: 'dancing', name: 'Dancing'),
    CategoryInfo(slug: 'priests', name: 'Priests'),
    CategoryInfo(slug: 'event_management', name: 'Event Management'),
  ];
}

/// Callbacks and state the shared top bar needs; owned by [AppShell].
class NavActions {
  const NavActions({
    required this.onHome,
    required this.onBrowseServices,
    required this.onCategorySelected,
    required this.onFindBooking,
    required this.onChangeLocation,
    required this.location,
  });
  final VoidCallback onHome;
  final VoidCallback onBrowseServices;
  final ValueChanged<String> onCategorySelected;
  final VoidCallback onFindBooking;
  final VoidCallback onChangeLocation;
  final LocationPref? location;
}

Widget _brandAppBar(BuildContext context, NavActions nav,
        List<CategoryInfo> categories, bool wide) =>
    SliverAppBar(
      pinned: true,
      toolbarHeight: 64,
      backgroundColor: _brandSurface,
      surfaceTintColor: Colors.transparent,
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: _brandBorder),
      ),
      title: Row(
        children: [
          InkWell(
            onTap: nav.onHome,
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset('assets/images/logo.jpg',
                      width: 44, height: 44),
                ),
                const SizedBox(width: 10),
                const Text(
                  'AnyBooking',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, letterSpacing: -.3),
                ),
              ],
            ),
          ),
          if (wide) ...[
            const SizedBox(width: 24),
            _navLink('All Services', nav.onBrowseServices),
            for (final category in categories.take(3))
              _navLink(
                  category.name, () => nav.onCategorySelected(category.name)),
            _navLink('Find My Booking', nav.onFindBooking, Icons.search),
          ],
        ],
      ),
      actions: [
        if (wide) ...[
          _locationControl(nav),
          const SizedBox(width: 16),
        ] else ...[
          IconButton(
            onPressed: nav.onChangeLocation,
            icon: Icon(
              nav.location == null
                  ? Icons.location_on_outlined
                  : Icons.location_on,
              color: nav.location == null ? null : _brandPrimary,
            ),
            tooltip: nav.location?.label ?? 'Set location',
          ),
          IconButton(
            onPressed: nav.onBrowseServices,
            icon: const Icon(Icons.search),
            tooltip: 'Find services',
          ),
        ],
      ],
    );

Widget _locationControl(NavActions nav) {
  final location = nav.location;
  if (location == null) {
    return OutlinedButton.icon(
      onPressed: nav.onChangeLocation,
      icon: const Icon(Icons.location_on_outlined, size: 16),
      label: const Text('Set Location'),
      style: OutlinedButton.styleFrom(foregroundColor: _brandPrimary),
    );
  }
  return Row(
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xffffedd5),
          border: Border.all(color: const Color(0xfffdba74)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            const Icon(Icons.location_on, size: 14, color: _brandPrimary),
            const SizedBox(width: 4),
            Text(
              location.label,
              style: const TextStyle(fontSize: 13, color: _brandText),
            ),
          ],
        ),
      ),
      TextButton(
        onPressed: nav.onChangeLocation,
        child: const Text('Change', style: TextStyle(fontSize: 12)),
      ),
    ],
  );
}

Widget _navLink(String label, VoidCallback onTap, [IconData? icon]) =>
    TextButton.icon(
      onPressed: onTap,
      icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: _brandTextSecondary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    );

class HomePage extends StatefulWidget {
  const HomePage({
    required this.api,
    required this.nav,
    required this.categories,
    required this.onSearch,
    super.key,
  });

  final BookingApi api;
  final NavActions nav;
  final List<CategoryInfo> categories;
  final ValueChanged<String> onSearch;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final banners = List.generate(
    5,
    (index) => 'assets/images/hero_banner_${index + 1}.jpg',
  );
  final searchController = TextEditingController();
  Timer? bannerTimer;
  int heroIndex = 0;
  late Future<List<Service>> services;

  @override
  void initState() {
    super.initState();
    services = widget.api.featuredServices();
    bannerTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) setState(() => heroIndex = (heroIndex + 1) % banners.length);
    });
  }

  @override
  void dispose() {
    bannerTimer?.cancel();
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= _wideBreakpoint;
    final gutter = _gutter(width);
    return SafeArea(
      child: CustomScrollView(
        slivers: [
          _brandAppBar(context, widget.nav, widget.categories, wide),
          SliverToBoxAdapter(child: _hero(wide)),
          SliverToBoxAdapter(
            child: _sectionHeader('Browse by Category', gutter, null),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            sliver: SliverGrid.count(
              crossAxisCount: wide ? 4 : 2,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: wide ? 1.9 : 1.35,
              children: [
                ...widget.categories.map(
                  (item) => _CategoryTile(
                    category: item,
                    onTap: () => widget.nav.onCategorySelected(item.name),
                  ),
                ),
                _ViewAllTile(onTap: widget.nav.onBrowseServices),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: _sectionHeader(
              'Featured Services',
              gutter,
              widget.nav.onBrowseServices,
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 390,
              child: FutureBuilder<List<Service>>(
                future: services,
                builder: (context, snapshot) {
                  final items = snapshot.data ?? Service.samples;
                  return ListView.separated(
                    padding: EdgeInsets.symmetric(horizontal: gutter),
                    scrollDirection: Axis.horizontal,
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 14),
                    itemBuilder: (_, index) => SizedBox(
                      width: 300,
                      child: ServiceCard(service: items[index]),
                    ),
                  );
                },
              ),
            ),
          ),
          SliverToBoxAdapter(child: _benefits(width, wide, gutter)),
        ],
      ),
    );
  }

  Widget _hero(bool wide) {
    final visible = wide ? 3 : 1;
    return SizedBox(
      height: wide ? 520 : 480,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Row(
            children: [
              for (var i = 0; i < visible; i++)
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 600),
                    child: Image.asset(
                      banners[(heroIndex + i) % banners.length],
                      key: ValueKey('$i-${(heroIndex + i) % banners.length}'),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                    ),
                  ),
                ),
            ],
          ),
          ColoredBox(color: Colors.black.withValues(alpha: .4)),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      "INDIA'S PREMIER EVENT BOOKING PLATFORM",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Find & Book the\nPerfect Venue',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: wide ? 44 : 30,
                        fontWeight: FontWeight.w900,
                        height: 1.15,
                        letterSpacing: -1.2,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Banquet halls, music bands, catering, hotels & more — '
                      'across India and beyond',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                    const SizedBox(height: 26),
                    _searchBox(),
                    const SizedBox(height: 26),
                    const Wrap(
                      spacing: 32,
                      runSpacing: 12,
                      alignment: WrapAlignment.center,
                      children: [
                        _HeroStat('500+', 'Verified Vendors'),
                        _HeroStat('15+', 'Service Categories'),
                        _HeroStat('50+', 'Cities Covered'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchBox() => Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        decoration: BoxDecoration(
          color: const Color(0xfffffaf5),
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(
                color: Colors.black26, blurRadius: 40, offset: Offset(0, 16)),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.search, color: Colors.grey),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: searchController,
                onSubmitted: widget.onSearch,
                textInputAction: TextInputAction.search,
                style: const TextStyle(color: _brandText, fontSize: 15),
                decoration: const InputDecoration.collapsed(
                  hintText: 'Search venues, services, cities…',
                ),
              ),
            ),
            FilledButton(
              onPressed: () => widget.onSearch(searchController.text.trim()),
              style: FilledButton.styleFrom(
                backgroundColor: _brandPrimary,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                'Search',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );

  Widget _sectionHeader(String title, double gutter, VoidCallback? action) =>
      Padding(
        padding: EdgeInsets.fromLTRB(gutter, 40, gutter, 16),
        child: Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                color: _brandText,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -.5,
              ),
            ),
            const Spacer(),
            if (action != null)
              TextButton(onPressed: action, child: const Text('View all →')),
          ],
        ),
      );

  Widget _benefits(double width, bool wide, double gutter) {
    const items = [
      (
        Icons.verified,
        'Verified Vendors',
        'Every vendor is reviewed before going live'
      ),
      (
        Icons.shield,
        'Secure Payments',
        'Razorpay-backed advance — safe & instant'
      ),
      (
        Icons.event_available,
        'Real Availability',
        'Live calendar — no double-bookings, ever'
      ),
      (
        Icons.headset_mic,
        'Dedicated Support',
        "We're with you from browse to event day"
      ),
    ];
    final itemWidth = wide
        ? (min(width, _contentMaxWidth) - 32 - 3 * 24) / 4
        : (width - 2 * gutter - 24) / 2;
    return Container(
      margin: const EdgeInsets.only(top: 40),
      padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 40),
      decoration: const BoxDecoration(
        color: Color(0xfffffaf5),
        border: Border.symmetric(horizontal: BorderSide(color: _brandBorder)),
      ),
      child: Wrap(
        spacing: 24,
        runSpacing: 28,
        children: [
          for (final item in items)
            SizedBox(
              width: itemWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xffffedd5),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(item.$1, color: _brandPrimary),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    item.$2,
                    style: const TextStyle(
                      color: _brandText,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.$3,
                    style: const TextStyle(
                      color: _brandTextSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat(this.value, this.label);
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      );
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.category, required this.onTap});
  final CategoryInfo category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, colors) =
        _categoryStyles[category.slug] ?? _defaultCategoryStyle;
    final count = category.count;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: colors,
              ),
            ),
            child: Center(child: Icon(icon, color: Colors.white, size: 40)),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black.withValues(alpha: .65), Colors.black12],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    category.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (count != null)
                    Text(
                      '$count listing${count == 1 ? '' : 's'}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(onTap: onTap),
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewAllTile extends StatelessWidget {
  const _ViewAllTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: _brandSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xfffdba74), width: 2),
        ),
        child: InkWell(
          onTap: onTap,
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.grid_view, color: _brandPrimary, size: 28),
              SizedBox(height: 8),
              Text(
                'View All',
                style: TextStyle(
                  color: _brandPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      );
}

const _bandGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xfffed7aa), Color(0xfffb923c), Color(0xffea580c)],
);

/// Centers page content to the site's max width with a 16px gutter.
class _Page extends StatelessWidget {
  const _Page({required this.child, this.maxWidth = _contentMaxWidth});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(width: double.infinity, child: child),
          ),
        ),
      );
}

/// The orange header band with breadcrumb, used at the top of inner pages.
class _PageBand extends StatelessWidget {
  const _PageBand({required this.crumbs, this.title, this.subtitle});
  final List<(String, VoidCallback?)> crumbs;
  final String? title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(gradient: _bandGradient),
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: _Page(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (var i = 0; i < crumbs.length; i++) ...[
                    if (i > 0)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child:
                            Text('›', style: TextStyle(color: Colors.white70)),
                      ),
                    InkWell(
                      onTap: crumbs[i].$2,
                      child: Text(
                        crumbs[i].$1,
                        style: TextStyle(
                          fontSize: 13,
                          color: crumbs[i].$2 == null
                              ? Colors.white70
                              : Colors.white,
                          decoration: crumbs[i].$2 == null
                              ? null
                              : TextDecoration.underline,
                          decorationColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (title != null) ...[
                const SizedBox(height: 10),
                Text(
                  title!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
              if (subtitle != null)
                Text(subtitle!,
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 14)),
            ],
          ),
        ),
      );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({this.title, required this.child});
  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _brandBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Text(
                title!,
                style: const TextStyle(
                  color: _brandText,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
            ],
            child,
          ],
        ),
      );
}

class _Pill extends StatelessWidget {
  const _Pill(this.label,
      {required this.background, required this.color, this.icon});
  final String label;
  final Color background;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(icon == null ? 6 : 999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 4)
            ],
            Text(label,
                style: TextStyle(
                    fontSize: 12, color: color, fontWeight: FontWeight.w600)),
          ],
        ),
      );
}

Widget _categoryBadge(String name) => _Pill(
      name,
      background: const Color(0xffffedd5),
      color: const Color(0xffc2410c),
    );

Widget _statusBadge(String? status) {
  final (bg, fg) = switch (status) {
    'confirmed' => (const Color(0xff198754), Colors.white),
    'pending' => (const Color(0xffffc107), Colors.black87),
    'cancelled' => (const Color(0xffdc3545), Colors.white),
    _ => (const Color(0xff6c757d), Colors.white),
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    decoration:
        BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
    child: Text(
      (status ?? 'pending')[0].toUpperCase() +
          (status ?? 'pending').substring(1),
      style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );
}

class _KeyValue extends StatelessWidget {
  const _KeyValue(this.label, this.value, {this.valueColor, this.bold = false});
  final String label;
  final String value;
  final Color? valueColor;
  final bool bold;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: Text(label,
                  style: const TextStyle(
                      color: _brandTextSecondary, fontSize: 13)),
            ),
            Expanded(
              flex: 3,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 13,
                  color: valueColor ?? _brandText,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      );
}

void _openService(BuildContext context, Service service) =>
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ServiceDetailPage(service: service)),
    );

class _ServiceImage extends StatelessWidget {
  const _ServiceImage(this.url);
  final String? url;

  @override
  Widget build(BuildContext context) {
    final fallback = Image.asset('assets/images/logo.jpg', fit: BoxFit.cover);
    if (url == null) return fallback;
    return Image.network(
      url!,
      fit: BoxFit.cover,
      width: double.infinity,
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}

Widget _attrBadge(ServiceOffering attr) {
  if (attr.displayValue == 'Yes') {
    return _Pill(attr.name,
        background: const Color(0xffdcfce7),
        color: const Color(0xff166534),
        icon: Icons.check_circle_outline);
  }
  if (attr.displayValue == 'No') {
    return _Pill(attr.name,
        background: const Color(0xfffee2e2),
        color: const Color(0xff991b1b),
        icon: Icons.cancel_outlined);
  }
  if (double.tryParse(attr.displayValue) != null) {
    return _Pill(attr.displayValue,
        background: const Color(0xffffedd5),
        color: const Color(0xffc2410c),
        icon: Icons.people_outline);
  }
  return const SizedBox.shrink();
}

Widget _starRow(double rating, {double size = 15}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            i <= rating.round() ? Icons.star : Icons.star_border,
            size: size,
            color: const Color(0xfff59e0b),
          ),
      ],
    );

class ServiceCard extends StatelessWidget {
  const ServiceCard({required this.service, super.key});
  final Service service;

  @override
  Widget build(BuildContext context) {
    final attrs = service.offerings
        .map(_attrBadge)
        .where((w) => w is! SizedBox)
        .take(3)
        .toList();
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openService(context, service),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                AspectRatio(
                    aspectRatio: 16 / 9,
                    child: _ServiceImage(service.imageUrl)),
                if (service.isFeatured)
                  const Positioned(
                    top: 10,
                    left: 10,
                    child: _Pill(
                      'Featured',
                      background: Color(0xfffb923c),
                      color: Color(0xff1a1a1a),
                      icon: Icons.star,
                    ),
                  ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _categoryBadge(service.category),
                        const SizedBox(width: 8),
                        const Icon(Icons.location_on_outlined,
                            size: 13, color: _brandTextSecondary),
                        Flexible(
                          child: Text(
                            service.city,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: _brandTextSecondary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      service.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _brandText,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (service.vendorName.isNotEmpty)
                      Text(
                        service.vendorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: _brandTextSecondary),
                      ),
                    const SizedBox(height: 8),
                    if (attrs.isNotEmpty)
                      Wrap(spacing: 6, runSpacing: 6, children: attrs),
                    if (service.rating > 0) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.star,
                              size: 14, color: Color(0xfff59e0b)),
                          const SizedBox(width: 3),
                          Text(
                            service.rating.toStringAsFixed(1),
                            style: const TextStyle(
                                fontSize: 13, color: Color(0xfff59e0b)),
                          ),
                          Text(
                            ' (${service.reviewCount})',
                            style: const TextStyle(
                                fontSize: 12, color: _brandTextSecondary),
                          ),
                        ],
                      ),
                    ],
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(child: _priceText(service)),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xffffedd5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'View →',
                            style: TextStyle(
                              color: Color(0xffc2410c),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _priceText(Service service, {double size = 17}) {
  if (service.priceValue <= 0) {
    return const Text('Price on request',
        style: TextStyle(fontSize: 13, color: _brandTextSecondary));
  }
  return Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '₹${_formatAmount(service.priceValue)}',
          style: TextStyle(
              color: _brandPrimary,
              fontSize: size,
              fontWeight: FontWeight.w800),
        ),
        if (service.priceUnit.isNotEmpty)
          TextSpan(
            text:
                ' / ${service.priceUnit.replaceFirst(RegExp(r'^(per|/)\s*'), '')}',
            style: const TextStyle(color: _brandTextSecondary, fontSize: 12),
          ),
        if (service.originalPriceLabel != null)
          TextSpan(
            text: '  ${service.originalPriceLabel}',
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 12,
              decoration: TextDecoration.lineThrough,
            ),
          ),
      ],
    ),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

/// Month grid showing free / booked days, like the Django availability widget.
/// Pass [onSelect] to make free days tappable (booking form).
class _AvailabilityCalendar extends StatefulWidget {
  const _AvailabilityCalendar(
      {required this.bookedDates, this.selected, this.onSelect});
  final Set<String> bookedDates;
  final DateTime? selected;
  final ValueChanged<DateTime>? onSelect;

  @override
  State<_AvailabilityCalendar> createState() => _AvailabilityCalendarState();
}

class _AvailabilityCalendarState extends State<_AvailabilityCalendar> {
  late DateTime month = DateTime(
    (widget.selected ?? DateTime.now()).year,
    (widget.selected ?? DateTime.now()).month,
  );

  static const _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  String _iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final startOfToday = DateTime(today.year, today.month, today.day);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final leading = DateTime(month.year, month.month, 1).weekday % 7;
    final cells = <Widget>[
      for (final d in const ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'])
        Center(
            child: Text(d,
                style:
                    const TextStyle(fontSize: 11, color: _brandTextSecondary))),
      for (var i = 0; i < leading; i++) const SizedBox.shrink(),
      for (var day = 1; day <= daysInMonth; day++)
        _dayCell(DateTime(month.year, month.month, day), startOfToday),
    ];
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xfff8fafc),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _monthButton(Icons.chevron_left, -1),
              Text(
                '${_monthNames[month.month - 1]} ${month.year}',
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              _monthButton(Icons.chevron_right, 1),
            ],
          ),
          const SizedBox(height: 6),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 3,
            crossAxisSpacing: 3,
            childAspectRatio: 1.25,
            children: cells,
          ),
        ],
      ),
    );
  }

  Widget _monthButton(IconData icon, int delta) => InkWell(
        onTap: () =>
            setState(() => month = DateTime(month.year, month.month + delta)),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
            padding: const EdgeInsets.all(2), child: Icon(icon, size: 20)),
      );

  Widget _dayCell(DateTime date, DateTime startOfToday) {
    final unavailable =
        date.isBefore(startOfToday) || widget.bookedDates.contains(_iso(date));
    final isSelected =
        widget.selected != null && _iso(widget.selected!) == _iso(date);
    final cell = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isSelected
            ? _brandPrimary
            : unavailable
                ? const Color(0xfffee2e2)
                : const Color(0xffdcfce7),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '${date.day}',
        style: TextStyle(
          fontSize: 12,
          color: isSelected
              ? Colors.white
              : unavailable
                  ? const Color(0xff991b1b)
                  : const Color(0xff166534),
        ),
      ),
    );
    if (unavailable || widget.onSelect == null) return cell;
    return InkWell(onTap: () => widget.onSelect!(date), child: cell);
  }
}

Widget _calendarLegend() => const Row(
      children: [
        _LegendDot(Color(0xffdcfce7), 'Available'),
        SizedBox(width: 16),
        _LegendDot(Color(0xfffee2e2), 'Booked'),
      ],
    );

class _LegendDot extends StatelessWidget {
  const _LegendDot(this.color, this.label);
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      );
}

class ServiceDetailPage extends StatefulWidget {
  const ServiceDetailPage({required this.service, super.key});
  final Service service;

  @override
  State<ServiceDetailPage> createState() => _ServiceDetailPageState();
}

class _ServiceDetailPageState extends State<ServiceDetailPage> {
  late Future<ServiceDetail?> detail;
  final galleryController = PageController();
  int galleryIndex = 0;

  @override
  void initState() {
    super.initState();
    detail = BookingApi().serviceDetail(widget.service.slug);
  }

  @override
  void dispose() {
    galleryController.dispose();
    super.dispose();
  }

  void _goHome() => Navigator.of(context).popUntil((route) => route.isFirst);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.service.name, overflow: TextOverflow.ellipsis),
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(1),
            child: Divider(height: 1, color: _brandBorder),
          ),
        ),
        body: FutureBuilder<ServiceDetail?>(
          future: detail,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snapshot.data;
            if (data == null) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Could not load this service.'),
                    TextButton(
                      onPressed: () => setState(() {
                        detail =
                            BookingApi().serviceDetail(widget.service.slug);
                      }),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              );
            }
            return _content(data);
          },
        ),
      );

  Widget _content(ServiceDetail d) {
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final s = d.service;
    final left = <Widget>[
      _gallery(d),
      const SizedBox(height: 16),
      _titleCard(d),
      if (!wide) _bookingPanel(d),
      if (d.description.isNotEmpty)
        _SectionCard(
          title: 'About',
          child: Text(d.description,
              style: const TextStyle(fontSize: 14, height: 1.5)),
        ),
      _SectionCard(title: 'Features & Details', child: _features(s)),
      _SectionCard(title: 'Contact', child: _contact(d)),
      _SectionCard(title: 'Reviews', child: _reviews(d)),
    ];
    return SingleChildScrollView(
      child: Column(
        children: [
          _PageBand(
            crumbs: [
              ('Home', _goHome),
              (s.category, _goHome),
              (s.name, null),
            ],
          ),
          _Page(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 8, child: Column(children: left)),
                        const SizedBox(width: 24),
                        SizedBox(width: 340, child: _bookingPanel(d)),
                      ],
                    )
                  : Column(children: left),
            ),
          ),
        ],
      ),
    );
  }

  Widget _gallery(ServiceDetail d) {
    final urls = d.imageUrls;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: urls.isEmpty
            ? Container(
                color: Colors.white,
                child:
                    Image.asset('assets/images/logo.jpg', fit: BoxFit.contain),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  PageView.builder(
                    controller: galleryController,
                    itemCount: urls.length,
                    onPageChanged: (i) => setState(() => galleryIndex = i),
                    itemBuilder: (_, i) => _ServiceImage(urls[i]),
                  ),
                  if (urls.length > 1)
                    Positioned(
                      bottom: 10,
                      left: 0,
                      right: 0,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < urls.length; i++)
                            Container(
                              width: 8,
                              height: 8,
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i == galleryIndex
                                    ? Colors.white
                                    : Colors.white54,
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _titleCard(ServiceDetail d) {
    final s = d.service;
    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              _categoryBadge(s.category),
              if (s.isFeatured)
                const _Pill(
                  'Featured',
                  background: Color(0xfffb923c),
                  color: Color(0xff1a1a1a),
                  icon: Icons.star,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            s.name,
            style: const TextStyle(
              color: _brandText,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: -.6,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 14,
            children: [
              if (s.vendorName.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.storefront_outlined,
                        size: 15, color: _brandTextSecondary),
                    const SizedBox(width: 4),
                    Text(s.vendorName,
                        style: const TextStyle(color: _brandTextSecondary)),
                  ],
                ),
              if (d.locationLine.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.location_on_outlined,
                        size: 15, color: _brandTextSecondary),
                    const SizedBox(width: 4),
                    Text(d.locationLine,
                        style: const TextStyle(color: _brandTextSecondary)),
                  ],
                ),
            ],
          ),
          if (s.rating > 0) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                _starRow(s.rating),
                const SizedBox(width: 8),
                Text(s.rating.toStringAsFixed(1),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(
                  '  (${d.reviews.length} review${d.reviews.length == 1 ? '' : 's'})',
                  style:
                      const TextStyle(color: _brandTextSecondary, fontSize: 13),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _features(Service s) {
    if (s.offerings.isEmpty) {
      return const Text('No features listed.',
          style: TextStyle(color: _brandTextSecondary));
    }
    return Wrap(
      spacing: 12,
      runSpacing: 10,
      children: [
        for (final a in s.offerings)
          SizedBox(
            width: 240,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xfffffaf5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _brandBorder),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    a.displayValue == 'Yes'
                        ? Icons.check_circle
                        : a.displayValue == 'No'
                            ? Icons.cancel
                            : Icons.info_outline,
                    size: 20,
                    color: a.displayValue == 'Yes'
                        ? Colors.green
                        : a.displayValue == 'No'
                            ? Colors.red
                            : _brandPrimary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.name,
                            style: const TextStyle(
                                fontSize: 12, color: _brandTextSecondary)),
                        Text(a.displayValue,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _contact(ServiceDetail d) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _contactRow(Icons.person_outline, d.service.vendorName, bold: true),
          if (d.vendorPhone.isNotEmpty)
            _contactRow(Icons.phone_outlined, d.vendorPhone),
          if (d.vendorEmail.isNotEmpty)
            _contactRow(Icons.mail_outline, d.vendorEmail),
        ],
      );

  Widget _contactRow(IconData icon, String text, {bool bold = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(icon, size: 17, color: _brandPrimary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(text,
                  style: TextStyle(
                      fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
            ),
          ],
        ),
      );

  Widget _reviews(ServiceDetail d) {
    if (d.reviews.isEmpty) {
      return const Text('No reviews yet.',
          style: TextStyle(color: _brandTextSecondary));
    }
    const avatarColors = [
      Color(0xfff97316),
      Color(0xffc2410c),
      Color(0xfff59e0b),
      Color(0xff16a34a),
      Color(0xff7c3aed),
      Color(0xffdc2626),
    ];
    return Column(
      children: [
        for (var i = 0; i < d.reviews.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: avatarColors[i % avatarColors.length],
                  child: Text(
                    d.reviews[i].name.isEmpty
                        ? '?'
                        : d.reviews[i].name[0].toUpperCase(),
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(d.reviews[i].name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          _starRow(d.reviews[i].rating.toDouble(), size: 13),
                          Text(d.reviews[i].date,
                              style: const TextStyle(
                                  fontSize: 12, color: _brandTextSecondary)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(d.reviews[i].body,
                          style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _bookingPanel(ServiceDetail d) {
    final s = d.service;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _brandBorder),
        boxShadow: const [
          BoxShadow(
              color: Color(0x14000000), blurRadius: 16, offset: Offset(0, 6))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _priceText(s, size: 28),
          const SizedBox(height: 14),
          const Row(
            children: [
              Icon(Icons.calendar_month_outlined, size: 16),
              SizedBox(width: 6),
              Text('Availability',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          _AvailabilityCalendar(bookedDates: d.bookedDates),
          const SizedBox(height: 10),
          _calendarLegend(),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      BookingFormPage(service: s, bookedDates: d.bookedDates),
                ),
              ),
              icon: const Icon(Icons.event_available),
              label: const Text('Book Now'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'No charges until confirmed',
              style: TextStyle(fontSize: 12, color: _brandTextSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class BookingFormPage extends StatefulWidget {
  const BookingFormPage({
    required this.service,
    this.bookedDates = const {},
    super.key,
  });
  final Service service;
  final Set<String> bookedDates;

  @override
  State<BookingFormPage> createState() => _BookingFormPageState();
}

class _BookingFormPageState extends State<BookingFormPage> {
  final formKey = GlobalKey<FormState>();
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final phoneController = TextEditingController();
  final guestCountController = TextEditingController(text: '1');
  final requestsController = TextEditingController();
  late final amountController = TextEditingController(
    text: widget.service.priceValue.toStringAsFixed(2),
  );
  final otpController = TextEditingController();
  DateTime? eventDate;
  bool termsAccepted = false;
  bool submitting = false;
  BookingResult? result;

  // Phone OTP verification (Firebase Phone Auth) — only enforced once a real
  // Firebase project exists (see firebaseConfigured). Until then, booking
  // proceeds on phone + form validation alone, same as before this feature.
  bool otpSending = false;
  bool otpSent = false;
  bool otpVerifying = false;
  bool phoneVerified = false;
  String? otpVerificationId;
  String? otpError;

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    phoneController.dispose();
    guestCountController.dispose();
    requestsController.dispose();
    amountController.dispose();
    otpController.dispose();
    super.dispose();
  }

  String _normalizedPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^\d+]'), '');
    return digits.startsWith('+') ? digits : '+91$digits';
  }

  Future<void> _sendOtp() async {
    if (phoneController.text.trim().isEmpty) {
      setState(() => otpError = 'Enter a phone number first.');
      return;
    }
    setState(() {
      otpError = null;
      otpSending = true;
    });
    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: _normalizedPhone(phoneController.text.trim()),
        verificationCompleted: (credential) async {
          await FirebaseAuth.instance.signInWithCredential(credential);
          if (mounted) {
            setState(() {
              phoneVerified = true;
              otpSending = false;
            });
          }
        },
        verificationFailed: (e) {
          if (mounted) {
            setState(() {
              otpError = e.message ?? 'Could not send OTP.';
              otpSending = false;
            });
          }
        },
        codeSent: (verificationId, resendToken) {
          if (mounted) {
            setState(() {
              otpVerificationId = verificationId;
              otpSent = true;
              otpSending = false;
            });
          }
        },
        codeAutoRetrievalTimeout: (verificationId) {
          otpVerificationId = verificationId;
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          otpError = 'Could not send OTP: $e';
          otpSending = false;
        });
      }
    }
  }

  Future<void> _verifyOtp() async {
    if (otpVerificationId == null) return;
    setState(() {
      otpError = null;
      otpVerifying = true;
    });
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: otpVerificationId!,
        smsCode: otpController.text.trim(),
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
      if (mounted) {
        setState(() {
          phoneVerified = true;
          otpVerifying = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          otpError = 'Invalid code — try again.';
          otpVerifying = false;
        });
      }
    }
  }

  Widget _otpSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        if (!otpSent)
          OutlinedButton.icon(
            onPressed: otpSending ? null : _sendOtp,
            icon: otpSending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.sms_outlined),
            label: const Text('Send OTP'),
          )
        else ...[
          TextFormField(
            controller: otpController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Enter OTP',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(
                onPressed: otpVerifying ? null : _verifyOtp,
                child: otpVerifying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : const Text('Verify'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: otpSending ? null : _sendOtp,
                child: const Text('Resend'),
              ),
            ],
          ),
        ],
        if (otpError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              otpError!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }

  void _goHome() => Navigator.of(context).popUntil((route) => route.isFirst);

  Widget _pair(bool wide, Widget a, Widget b) => wide
      ? Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: a),
            const SizedBox(width: 12),
            Expanded(child: b)
          ],
        )
      : Column(children: [a, const SizedBox(height: 12), b]);

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          text,
          style: const TextStyle(
              color: _brandText, fontSize: 18, fontWeight: FontWeight.w800),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final booked = result != null && result!.error == null;
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final s = widget.service;
    return Scaffold(
      appBar: AppBar(
        title: Text('Book: ${s.name}', overflow: TextOverflow.ellipsis),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: _brandBorder),
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            _PageBand(
              crumbs: [
                ('Home', _goHome),
                (s.name, () => Navigator.of(context).pop()),
                ('Book', null),
              ],
            ),
            _Page(
              maxWidth: 960,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: booked ? _confirmationView(result!) : _bookingBody(wide),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bookingBody(bool wide) {
    final s = widget.service;
    final form = _formCard(wide);
    final side = Column(
      children: [
        _SectionCard(
          title: 'Availability',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AvailabilityCalendar(
                bookedDates: widget.bookedDates,
                selected: eventDate,
                onSelect: (d) => setState(() => eventDate = d),
              ),
              const SizedBox(height: 10),
              _calendarLegend(),
              const SizedBox(height: 6),
              const Text(
                'Tap a free day to choose your event date.',
                style: TextStyle(fontSize: 12, color: _brandTextSecondary),
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Booking Summary',
          child: Column(
            children: [
              _KeyValue('Service', s.name, bold: true),
              _KeyValue('Category', s.category),
              _KeyValue('Location', s.city),
              _KeyValue('Price', s.priceValue <= 0 ? 'On request' : s.price,
                  valueColor: _brandPrimary, bold: true),
              if (eventDate != null)
                _KeyValue('Event Date', _isoDate(eventDate!), bold: true),
            ],
          ),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Book: ${s.name}',
          style: const TextStyle(
              color: _brandText, fontSize: 24, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Text(
            '${s.city}  ·  ${s.priceValue <= 0 ? 'Price on request' : s.price}',
            style: const TextStyle(color: _brandTextSecondary),
          ),
        ),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 7, child: form),
              const SizedBox(width: 20),
              Expanded(flex: 5, child: side),
            ],
          )
        else ...[form, side],
      ],
    );
  }

  String _isoDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Widget _formCard(bool wide) => _SectionCard(
        child: Form(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _heading('Your Details'),
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Full Name *'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              _pair(
                wide,
                TextFormField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration:
                      const InputDecoration(labelText: 'Email (optional)'),
                  validator: (v) =>
                      (v != null && v.isNotEmpty && !v.contains('@'))
                          ? 'Enter a valid email'
                          : null,
                ),
                TextFormField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  enabled: !phoneVerified,
                  decoration: InputDecoration(
                    labelText: 'Phone *',
                    suffixIcon: phoneVerified
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : null,
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                  onChanged: (_) {
                    if (otpSent || phoneVerified) {
                      setState(() {
                        otpSent = false;
                        phoneVerified = false;
                        otpVerificationId = null;
                        otpController.clear();
                      });
                    }
                  },
                ),
              ),
              if (firebaseConfigured && !phoneVerified) ...[
                const SizedBox(height: 8),
                _otpSection(),
              ],
              const Divider(height: 32),
              _heading('Event Details'),
              _pair(
                wide,
                InkWell(
                  onTap: _pickDate,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Event Date *',
                      suffixIcon: Icon(Icons.calendar_today_outlined),
                    ),
                    child: Text(eventDate == null
                        ? 'Select a date'
                        : _isoDate(eventDate!)),
                  ),
                ),
                TextFormField(
                  controller: guestCountController,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Number of Guests *'),
                  validator: (v) =>
                      (int.tryParse(v ?? '') == null) ? 'Enter a number' : null,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: amountController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Total amount (₹)'),
                validator: (v) => (double.tryParse(v ?? '') == null)
                    ? 'Enter an amount'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: requestsController,
                maxLines: 3,
                decoration:
                    const InputDecoration(labelText: 'Special Requests'),
              ),
              if (widget.service.cancellationPolicy.isNotEmpty) ...[
                const SizedBox(height: 12),
                Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text(
                      'Cancellation policy',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(widget.service.cancellationPolicy),
                      ),
                    ],
                  ),
                ),
              ],
              const Divider(height: 32),
              _heading('Terms of Use'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: termsAccepted,
                onChanged: (v) => setState(() => termsAccepted = v ?? false),
                title: const Text(
                  'I have read and agree to the Terms of Use',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (result?.error != null) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xfff8d7da),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(result!.error!,
                      style: const TextStyle(color: Color(0xff842029))),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: submitting ? null : _submit,
                  icon: submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.event_available),
                  label: const Text('Confirm Booking Request'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Center(
                child: Text(
                  'Our team will contact you within 24 hours to confirm.',
                  style: TextStyle(fontSize: 12, color: _brandTextSecondary),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _confirmationView(BookingResult r) {
    final pending = r.status != 'confirmed';
    final total = r.totalAmount ?? double.tryParse(amountController.text) ?? 0;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: _SectionCard(
          child: Column(
            children: [
              Icon(
                pending ? Icons.schedule : Icons.check_circle,
                size: 60,
                color:
                    pending ? const Color(0xffffc107) : Colors.green.shade600,
              ),
              const SizedBox(height: 12),
              Text(
                pending ? 'Booking Requested!' : 'Booking Confirmed!',
                style:
                    const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                pending
                    ? 'Your request is pending. Our team will contact you within 24 hours.'
                    : 'Your payment was received and the booking is confirmed.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _brandTextSecondary),
              ),
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xffffedd5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    const Text(
                      'Your Confirmation Number',
                      style:
                          TextStyle(fontSize: 12, color: _brandTextSecondary),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      r.confirmationNumber ?? '-',
                      style: const TextStyle(
                        color: _brandPrimary,
                        fontSize: 24,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Use this to find or reference your booking',
                      style:
                          TextStyle(fontSize: 12, color: _brandTextSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xfff8f9fa),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    if (r.id != null)
                      _KeyValue('Booking ID', '#${r.id}', bold: true),
                    _KeyValue('Service', r.serviceName ?? widget.service.name,
                        bold: true),
                    _KeyValue('Location', widget.service.city),
                    _KeyValue(
                        'Customer', r.customerName ?? nameController.text),
                    _KeyValue('Phone', r.customerPhone ?? phoneController.text),
                    _KeyValue(
                      'Event Date',
                      r.eventDate ??
                          (eventDate == null ? '' : _isoDate(eventDate!)),
                    ),
                    _KeyValue('Guests',
                        '${r.guestCount ?? guestCountController.text}'),
                    _KeyValue(
                      'Total Amount',
                      '₹${_formatAmount(total)}',
                      valueColor: _brandPrimary,
                      bold: true,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          const Expanded(
                            flex: 2,
                            child: Text('Status',
                                style: TextStyle(
                                    color: _brandTextSecondary, fontSize: 13)),
                          ),
                          Expanded(
                            flex: 3,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: _statusBadge(r.status),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: _goHome,
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('Browse More Services'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: eventDate ?? now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 730)),
    );
    if (picked != null) setState(() => eventDate = picked);
  }

  Future<void> _submit() async {
    final isValid = formKey.currentState?.validate() ?? false;
    if (!isValid) return;
    if (eventDate == null) {
      setState(() => result = BookingResult.error('Select an event date.'));
      return;
    }
    if (!termsAccepted) {
      setState(
        () => result = BookingResult.error('Please accept the terms.'),
      );
      return;
    }
    if (firebaseConfigured && !phoneVerified) {
      setState(
        () => result = BookingResult.error('Please verify your phone number.'),
      );
      return;
    }

    String? firebaseIdToken;
    if (firebaseConfigured) {
      try {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          firebaseIdToken = await user.getIdToken();
        }
      } on Exception {
        // If we can't get a token, continue without it; the backend will
        // reject if enforcement is enabled.
      }
    }

    setState(() {
      submitting = true;
      result = null;
    });
    final value = await BookingApi().createBooking(
      serviceSlug: widget.service.slug,
      customerName: nameController.text.trim(),
      customerEmail: emailController.text.trim(),
      customerPhone: phoneController.text.trim(),
      eventDate: eventDate!,
      guestCount: int.parse(guestCountController.text),
      totalAmount: double.parse(amountController.text),
      specialRequests: requestsController.text.trim(),
      firebaseIdToken: firebaseIdToken,
    );
    if (mounted) {
      setState(() {
        submitting = false;
        result = value;
      });
    }
  }
}

class ServicesPage extends StatefulWidget {
  const ServicesPage({
    required this.api,
    required this.nav,
    required this.categories,
    this.initialCategory,
    this.initialQuery = '',
    this.location,
    super.key,
  });
  final BookingApi api;
  final NavActions nav;
  final List<CategoryInfo> categories;
  final String? initialCategory;
  final String initialQuery;
  final LocationPref? location;

  @override
  State<ServicesPage> createState() => _ServicesPageState();
}

class _ServicesPageState extends State<ServicesPage> {
  final searchController = TextEditingController();
  List<Service> services = Service.samples;
  String? categoryFilter;
  bool loadFailed = false;
  String? loadError;

  List<Country> countries = [];
  List<StateOption> stateOptions = [];
  int? selectedCountryId;
  int? selectedStateId;
  bool parkingOnly = false;
  String sort = '';

  @override
  void initState() {
    super.initState();
    categoryFilter = widget.initialCategory;
    searchController.text = widget.initialQuery;
    selectedCountryId = widget.location?.countryId;
    selectedStateId = widget.location?.stateId;
    if (selectedCountryId != null) {
      widget.api.states(selectedCountryId!).then((value) {
        if (mounted) setState(() => stateOptions = value);
      });
    }
    _loadServices();
    widget.api.countries().then((value) {
      if (mounted) setState(() => countries = value);
    });
  }

  void _loadServices() {
    loadFailed = false;
    widget.api
        .services(
      category: BookingApi.categorySlug(categoryFilter),
      countryId: selectedCountryId,
      stateId: selectedStateId,
      parkingOnly: parkingOnly,
    )
        .then((value) {
      if (mounted) setState(() => services = value);
    }).catchError((error) {
      debugPrint('Failed to load services: $error');
      reportClientError(message: 'Failed to load services: $error');
      if (mounted) {
        setState(() {
          loadFailed = true;
          loadError = error.toString();
        });
      }
    });
  }

  void _onCountryChanged(int? countryId) {
    setState(() {
      selectedCountryId = countryId;
      selectedStateId = null;
      stateOptions = [];
    });
    _loadServices();
    if (countryId != null) {
      widget.api.states(countryId).then((value) {
        if (mounted) setState(() => stateOptions = value);
      });
    }
  }

  void _onStateChanged(int? stateId) {
    setState(() => selectedStateId = stateId);
    _loadServices();
  }

  void _onParkingChanged(bool value) {
    setState(() => parkingOnly = value);
    _loadServices();
  }

  void _selectCategory(String? name) {
    setState(() => categoryFilter = name);
    _loadServices();
  }

  void _clearFilters() {
    setState(() {
      searchController.clear();
      sort = '';
      parkingOnly = false;
      categoryFilter = null;
    });
    _loadServices();
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  List<Service> get _visible {
    final query = searchController.text.trim().toLowerCase();
    final list = services.where((s) {
      if (categoryFilter != null && s.category != categoryFilter) return false;
      if (query.isEmpty) return true;
      return s.name.toLowerCase().contains(query) ||
          s.category.toLowerCase().contains(query) ||
          s.city.toLowerCase().contains(query) ||
          s.vendorName.toLowerCase().contains(query);
    }).toList();
    if (sort == 'price_asc') {
      list.sort((a, b) => a.priceValue.compareTo(b.priceValue));
    } else if (sort == 'price_desc') {
      list.sort((a, b) => b.priceValue.compareTo(a.priceValue));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= _wideBreakpoint;
    final visible = _visible;
    final (icon, _) = _categoryStyles[widget.categories
            .where((c) => c.name == categoryFilter)
            .firstOrNull
            ?.slug] ??
        _defaultCategoryStyle;
    return SafeArea(
      child: CustomScrollView(
        slivers: [
          _brandAppBar(context, widget.nav, widget.categories, wide),
          SliverToBoxAdapter(
            child: _PageBand(
              crumbs: [
                ('Home', widget.nav.onHome),
                if (categoryFilter == null)
                  ('All Services', null)
                else ...[
                  ('Services', () => _selectCategory(null)),
                  (categoryFilter!, null),
                ],
              ],
              title: categoryFilter ?? 'All Services',
              subtitle:
                  '${visible.length} result${visible.length == 1 ? '' : 's'} found',
            ),
          ),
          SliverToBoxAdapter(child: _searchStrip()),
          if (loadFailed)
            SliverToBoxAdapter(
              child: _Page(
                child: Container(
                  margin: const EdgeInsets.only(top: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          loadError == null
                              ? 'Could not load live listings — showing samples.'
                              : 'Could not load live listings — showing samples.\n$loadError',
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(_loadServices),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: _Page(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (wide) ...[
                      SizedBox(width: 230, child: _sidebar(icon)),
                      const SizedBox(width: 24),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!wide) _categoryChips(),
                          _results(visible),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchStrip() => Container(
        decoration: const BoxDecoration(
          color: _brandSurface,
          border: Border(bottom: BorderSide(color: _brandBorder)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: _Page(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 240,
                child: TextField(
                  controller: searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: 'Search…',
                  ),
                ),
              ),
              _filterDropdown<int?>(
                width: 170,
                value: countries.any((c) => c.id == selectedCountryId)
                    ? selectedCountryId
                    : null,
                hint: 'All Countries',
                items: {for (final c in countries) c.id: c.name},
                onChanged: _onCountryChanged,
              ),
              _filterDropdown<int?>(
                width: 170,
                value: stateOptions.any((s) => s.id == selectedStateId)
                    ? selectedStateId
                    : null,
                hint: 'All States',
                items: {for (final s in stateOptions) s.id: s.name},
                onChanged: selectedCountryId == null ? null : _onStateChanged,
              ),
              _filterDropdown<String?>(
                width: 160,
                value: sort.isEmpty ? null : sort,
                hint: 'Relevance',
                items: const {'price_asc': 'Price ↑', 'price_desc': 'Price ↓'},
                onChanged: (v) => setState(() => sort = v ?? ''),
              ),
              FilterChip(
                label: const Text('Parking'),
                avatar: const Icon(Icons.local_parking, size: 18),
                selected: parkingOnly,
                onSelected: _onParkingChanged,
              ),
              TextButton(onPressed: _clearFilters, child: const Text('Clear')),
            ],
          ),
        ),
      );

  Widget _filterDropdown<T>({
    required double width,
    required T? value,
    required String hint,
    required Map<T, String> items,
    required ValueChanged<T?>? onChanged,
  }) =>
      SizedBox(
        width: width,
        child: DropdownButtonFormField<T?>(
          key: ValueKey('$hint-$value-${items.length}'),
          initialValue: value,
          isExpanded: true,
          isDense: true,
          decoration: const InputDecoration(isDense: true),
          items: [
            DropdownMenuItem<T?>(value: null, child: Text(hint)),
            for (final e in items.entries)
              DropdownMenuItem<T?>(
                  value: e.key,
                  child: Text(e.value, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: onChanged,
        ),
      );

  Widget _sidebar(IconData _) {
    final total =
        widget.categories.fold<int>(0, (sum, c) => sum + (c.count ?? 0));
    Widget pill(String label, int? count, bool active, VoidCallback onTap) =>
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            margin: const EdgeInsets.only(bottom: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: active ? const Color(0xffffedd5) : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active
                          ? const Color(0xffc2410c)
                          : const Color(0xff475569),
                    ),
                  ),
                ),
                if (count != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                    decoration: BoxDecoration(
                      color: active ? const Color(0xfffdba74) : _brandBorder,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 11,
                        color: active
                            ? const Color(0xffc2410c)
                            : _brandTextSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xfffffaf5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _brandBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'CATEGORIES',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: .6,
              color: _brandTextSecondary,
            ),
          ),
          const SizedBox(height: 8),
          pill('All', total, categoryFilter == null,
              () => _selectCategory(null)),
          for (final c in widget.categories)
            pill(c.name, c.count, categoryFilter == c.name,
                () => _selectCategory(c.name)),
        ],
      ),
    );
  }

  Widget _categoryChips() => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('All'),
                selected: categoryFilter == null,
                onSelected: (_) => _selectCategory(null),
              ),
              for (final c in widget.categories) ...[
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text(c.name),
                  selected: categoryFilter == c.name,
                  onSelected: (_) => _selectCategory(c.name),
                ),
              ],
            ],
          ),
        ),
      );

  Widget _results(List<Service> visible) {
    if (visible.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.search, size: 48, color: _brandTextSecondary),
              SizedBox(height: 12),
              Text('No services found',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              SizedBox(height: 4),
              Text('Try adjusting your filters.',
                  style: TextStyle(color: _brandTextSecondary)),
            ],
          ),
        ),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: visible.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 330,
        mainAxisExtent: 390,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
      ),
      itemBuilder: (_, i) => ServiceCard(service: visible[i]),
    );
  }
}

class BookingLookupPage extends StatefulWidget {
  const BookingLookupPage({
    required this.nav,
    required this.categories,
    super.key,
  });
  final NavActions nav;
  final List<CategoryInfo> categories;

  @override
  State<BookingLookupPage> createState() => _BookingLookupPageState();
}

class _BookingLookupPageState extends State<BookingLookupPage> {
  final confirmationController = TextEditingController();
  final lastNameController = TextEditingController();
  final phoneController = TextEditingController();
  BookingResult? result;
  bool loading = false;

  @override
  void dispose() {
    confirmationController.dispose();
    lastNameController.dispose();
    phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    return SafeArea(
      child: CustomScrollView(
        slivers: [
          _brandAppBar(context, widget.nav, widget.categories, wide),
          SliverToBoxAdapter(
            child: _Page(
              maxWidth: 680,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Column(
                  children: [
                    const Icon(Icons.search, size: 44, color: _brandPrimary),
                    const SizedBox(height: 8),
                    const Text(
                      'Find My Booking',
                      style: TextStyle(
                          color: _brandText,
                          fontSize: 28,
                          fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Enter your confirmation number, or your last name and phone number.\n'
                      'Only pending and confirmed bookings are shown.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _brandTextSecondary),
                    ),
                    const SizedBox(height: 24),
                    _form(wide),
                    if (result != null) ...[
                      const SizedBox(height: 24),
                      _resultView(result!),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _form(bool wide) {
    final lastName = TextField(
      controller: lastNameController,
      decoration: const InputDecoration(
        labelText: 'Last Name',
        hintText: 'e.g. Sharma',
        prefixIcon: Icon(Icons.person_outline),
      ),
    );
    final phone = TextField(
      controller: phoneController,
      keyboardType: TextInputType.phone,
      decoration: const InputDecoration(
        labelText: 'Phone Number',
        hintText: 'e.g. 9876543210',
        prefixIcon: Icon(Icons.phone_outlined),
      ),
    );
    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: confirmationController,
            textCapitalization: TextCapitalization.characters,
            style: const TextStyle(fontFamily: 'monospace', letterSpacing: 1.2),
            decoration: const InputDecoration(
              labelText: 'Confirmation Number',
              hintText: 'e.g. AB-K3M7X9QP',
              helperText: 'Found in your booking confirmation email.',
              prefixIcon: Icon(Icons.confirmation_number_outlined),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('OR',
                      style: TextStyle(
                          color: _brandTextSecondary,
                          fontWeight: FontWeight.w600)),
                ),
                Expanded(child: Divider()),
              ],
            ),
          ),
          if (wide)
            Row(
              children: [
                Expanded(child: lastName),
                const SizedBox(width: 12),
                Expanded(child: phone),
              ],
            )
          else ...[lastName, const SizedBox(height: 12), phone],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: loading ? null : _lookup,
              icon: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
              label: const Text('Find Booking'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultView(BookingResult r) {
    if (r.error != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xfffff3cd),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xff997404)),
            const SizedBox(width: 10),
            Expanded(
                child: Text(r.error!,
                    style: const TextStyle(color: Color(0xff664d03)))),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('1 booking found',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _brandBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Container(
                color: const Color(0xfffff7ed),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        r.confirmationNumber ?? '',
                        style: const TextStyle(
                          color: _brandPrimary,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    _statusBadge(r.status),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    _KeyValue('Service', r.serviceName ?? '', bold: true),
                    _KeyValue('Customer', r.customerName ?? ''),
                    _KeyValue('Event Date', r.eventDate ?? '', bold: true),
                    _KeyValue('Guests', '${r.guestCount ?? ''}'),
                    _KeyValue(
                      'Total',
                      r.totalAmount == null
                          ? ''
                          : '₹${_formatAmount(r.totalAmount!)}',
                      valueColor: _brandPrimary,
                      bold: true,
                    ),
                    if ((r.advanceAmount ?? 0) > 0) ...[
                      _KeyValue(
                          'Advance Paid', '₹${_formatAmount(r.advanceAmount!)}',
                          valueColor: Colors.green.shade700),
                      _KeyValue('Balance Due',
                          '₹${_formatAmount((r.totalAmount ?? 0) - r.advanceAmount!)}'),
                    ],
                    const Divider(height: 24),
                    Row(
                      children: [
                        if (r.cancellationRequested)
                          const _Pill(
                            'Cancellation Pending',
                            background: Color(0xffffc107),
                            color: Colors.black87,
                            icon: Icons.hourglass_top,
                          ),
                        const Spacer(),
                        if (r.isActive && !r.cancellationRequested)
                          OutlinedButton.icon(
                            onPressed: () => Navigator.of(context)
                                .push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        CancelRequestPage(booking: r),
                                  ),
                                )
                                .then((_) => _lookup(silent: true)),
                            icon: const Icon(Icons.cancel_outlined, size: 18),
                            label: const Text('Request Cancellation'),
                            style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red.shade700),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _lookup({bool silent = false}) async {
    final confirmation = confirmationController.text.trim().toUpperCase();
    final lastName = lastNameController.text.trim();
    final phone = phoneController.text.trim();
    if (confirmation.isEmpty && (lastName.isEmpty || phone.isEmpty)) {
      setState(() => result = BookingResult.error(
            'Enter a confirmation number, or both your last name and phone number.',
          ));
      return;
    }
    if (!silent) {
      setState(() {
        loading = true;
        result = null;
      });
    }
    final value = await BookingApi().lookupBooking(
      confirmationNumber: confirmation,
      lastName: lastName,
      phone: phone,
    );
    if (mounted) {
      setState(() {
        loading = false;
        result = value;
      });
    }
  }
}

class CancelRequestPage extends StatefulWidget {
  const CancelRequestPage({required this.booking, super.key});
  final BookingResult booking;

  @override
  State<CancelRequestPage> createState() => _CancelRequestPageState();
}

class _CancelRequestPageState extends State<CancelRequestPage> {
  final reasonController = TextEditingController();
  bool submitting = false;
  bool submitted = false;
  String? error;

  @override
  void dispose() {
    reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = reasonController.text.trim();
    if (reason.isEmpty) {
      setState(() => error = 'Please tell us why you would like to cancel.');
      return;
    }
    setState(() {
      submitting = true;
      error = null;
    });
    final message = await BookingApi().requestCancellation(
      widget.booking.confirmationNumber ?? '',
      reason,
    );
    if (!mounted) return;
    setState(() {
      submitting = false;
      if (message == null) {
        submitted = true;
      } else {
        error = message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    return Scaffold(
      appBar: AppBar(
        title: Text('Request Cancellation — ${b.confirmationNumber ?? ''}'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: _brandBorder),
        ),
      ),
      body: SingleChildScrollView(
        child: _Page(
          maxWidth: 600,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: submitted ? _done(b) : _form(b),
          ),
        ),
      ),
    );
  }

  Widget _done(BookingResult b) => _SectionCard(
        child: Column(
          children: [
            const Icon(Icons.hourglass_top, size: 56, color: Color(0xffffc107)),
            const SizedBox(height: 12),
            const Text('Request Submitted',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              'Your cancellation request for booking ${b.confirmationNumber} has been '
              'received. Our team will review it and contact you shortly with the next steps.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: _brandTextSecondary),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.search, size: 18),
              label: const Text('Back to Find My Booking'),
            ),
          ],
        ),
      );

  Widget _form(BookingResult b) => _SectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Request Cancellation',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              'Booking ${b.confirmationNumber}',
              style: const TextStyle(
                  color: _brandPrimary,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xfff8f9fa),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  _KeyValue('Service', b.serviceName ?? '', bold: true),
                  _KeyValue('Event Date', b.eventDate ?? '', bold: true),
                  _KeyValue('Guests', '${b.guestCount ?? ''}'),
                  _KeyValue(
                    'Total Amount',
                    b.totalAmount == null
                        ? ''
                        : '₹${_formatAmount(b.totalAmount!)}',
                    valueColor: _brandPrimary,
                    bold: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xfffff3cd),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 18, color: Color(0xff997404)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Submitting this request does not cancel your booking immediately. '
                      'Our team will review it and contact you about any applicable refund.',
                      style: TextStyle(fontSize: 13, color: Color(0xff664d03)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: reasonController,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: 'Reason for cancellation *',
                hintText:
                    "Please tell us why you'd like to cancel this booking…",
                errorText: error,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: submitting ? null : _submit,
                icon: submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cancel_outlined),
                label: const Text('Submit Cancellation Request'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('Back'),
              ),
            ),
          ],
        ),
      );
}

class VendorPage extends StatefulWidget {
  const VendorPage({super.key});
  @override
  State<VendorPage> createState() => _VendorPageState();
}

class _VendorPageState extends State<VendorPage> {
  final username = TextEditingController();
  final password = TextEditingController();
  bool loading = false;
  String? message;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 24),
            Text(
              'Vendor portal',
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text('Manage your listings and bookings from one place.'),
            const SizedBox(height: 24),
            TextField(
              controller: username,
              decoration: const InputDecoration(
                labelText: 'Username',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: loading ? null : _login,
              child: loading
                  ? const CircularProgressIndicator()
                  : const Text('Sign in'),
            ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(message!),
              ),
          ],
        ),
      );

  Future<void> _login() async {
    setState(() {
      loading = true;
      message = null;
    });
    final ok = await BookingApi().vendorLogin(
      username.text.trim(),
      password.text,
    );
    if (mounted) {
      setState(() {
        loading = false;
        message = ok
            ? 'Signed in successfully.'
            : 'Sign-in failed. Please check your details.';
      });
    }
  }
}
