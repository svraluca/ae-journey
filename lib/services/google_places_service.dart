import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// Pulls REAL clinic data from Places API (New):
/// `places:searchText` → `places/{id}`. Returns verified address, phone,
/// website, opening hours, lat/lng, Google rating, total review count,
/// and the latest reviews (up to 5).
///
/// Legacy `maps.googleapis.com/maps/api/place/*` is not enabled on this
/// project — those calls return REQUEST_DENIED.
///
/// Set `GOOGLE_PLACES_API_KEY` (or pass it explicitly) in `.env`.
/// Without a key the service is a no-op: methods return `null`.
class GooglePlacesService {
  GooglePlacesService({http.Client? client, String? apiKey,
    DateTime Function()? now})
    : _client = client ?? http.Client(),
      _now = now ?? DateTime.now,
      _apiKey = apiKey ?? _readKey();

  final DateTime Function() _now;
  static final Map<String, DateTime> _unratedCacheUntil = {};
  static const _unratedCacheTtl = Duration(minutes: 2);

  static const _host = 'places.googleapis.com';

  /// Session-wide Places quota breaker. Once Places returns 429 /
  /// RESOURCE_EXHAUSTED, stop further SearchText/GetPlace calls for this
  /// app session so every candidate does not burn the same failing quota.
  /// Shared across every [GooglePlacesService] instance in the isolate.
  static bool _quotaCircuitOpen = false;

  /// In-flight HTTP ops that started before the breaker opened may finish.
  static int _inFlightHttp = 0;

  /// True when Places detail/search must not be called this session.
  static bool get quotaCircuitOpen => _quotaCircuitOpen;

  /// Test helper: how many Places HTTP ops are currently running.
  @visibleForTesting
  static int get inFlightHttpForTest => _inFlightHttp;

  /// Clears the circuit breaker (e.g. after credits / new day). Prefer
  /// leaving it open within a session once daily quota is hit.
  static void resetQuotaCircuitBreaker() {
    if (_quotaCircuitOpen) {
      debugPrint('[GP] Places circuit breaker reset');
    }
    _quotaCircuitOpen = false;
  }

  /// Test / recovery helper: trip the breaker as if Places returned 429.
  @visibleForTesting
  static void notePlacesQuotaFailureForTest({
    int statusCode = 429,
    String body = 'RESOURCE_EXHAUSTED',
  }) {
    _tripQuotaCircuit(
      op: 'test',
      statusCode: statusCode,
      status: 'RESOURCE_EXHAUSTED',
      message: body,
    );
  }

  /// Acquire a permit for a new Places Search/Details wave.
  /// Returns false when the shared breaker is open — callers must not launch.
  static bool tryAcquirePlacesHttpPermit() {
    if (_quotaCircuitOpen) return false;
    _inFlightHttp++;
    return true;
  }

  static void releasePlacesHttpPermit() {
    if (_inFlightHttp > 0) _inFlightHttp--;
  }

  static void _tripQuotaCircuit({
    required String op,
    required int statusCode,
    required String status,
    required String message,
  }) {
    final blob = '$status $message'.toUpperCase();
    final quota =
        statusCode == 429 ||
        blob.contains('RESOURCE_EXHAUSTED') ||
        blob.contains('RATE_LIMIT') ||
        blob.contains('QUOTA');
    if (!quota) return;
    if (_quotaCircuitOpen) return;
    _quotaCircuitOpen = true;
    debugPrint(
      '[GP] Places circuit breaker ON · $op · HTTP $statusCode · '
      '$status · stop further Places detail/search this session '
      '(inFlight=$_inFlightHttp may finish)',
    );
  }

  static const _liteFields = [
    'id',
    'displayName',
    'formattedAddress',
    'internationalPhoneNumber',
    'nationalPhoneNumber',
    'websiteUri',
    'rating',
    'userRatingCount',
    'location',
    'googleMapsUri',
    'businessStatus',
  ];

  static const _fullFields = [
    ..._liteFields,
    'regularOpeningHours',
    'currentOpeningHours',
    'reviews',
    'editorialSummary',
    'addressComponents',
  ];

  static const _searchHitFields = [
    'places.id',
    'places.displayName',
    'places.formattedAddress',
    'places.rating',
    'places.userRatingCount',
    'places.location',
    'places.types',
  ];

  final http.Client _client;
  final String _apiKey;

  /// Session cache so repeated `(clinic, city)` lookups are instant.
  static final Map<String, Future<GooglePlacesResult?>> _cache = {};
  static final Map<String, Future<List<GooglePlacesSearchHit>>>
  _textSearchCache = {};
  static final Map<String, Future<GooglePlacesResult?>> _placeIdCache = {};

  bool get isConfigured => _apiKey.trim().isNotEmpty;

  /// Text Search for additional clinic candidates when Compare is short of 4.
  Future<List<GooglePlacesSearchHit>> searchText({
    required String query,
    required String city,
    int maxResults = 8,
  }) {
    final q = query.trim();
    if (q.isEmpty || !isConfigured) {
      return Future.value(const []);
    }
    if (_quotaCircuitOpen) {
      return Future.value(const []);
    }
    final key =
        'text|${q.toLowerCase()}|${city.trim().toLowerCase()}|$maxResults';
    final pending = _textSearchCache[key];
    if (pending != null) return pending;
    if (!tryAcquirePlacesHttpPermit()) {
      return Future.value(const []);
    }
    final fut = _searchTextUncached(
      query: q,
      city: city,
      maxResults: maxResults,
    ).whenComplete(releasePlacesHttpPermit);
    _textSearchCache[key] = fut;
    return fut;
  }

  /// Resolve a typed city into a Places locality (placeId + lat/lng + country).
  /// Used by the Explore location picker so discovery is geo-wired worldwide.
  Future<GooglePlacesLocalityHit?> resolveLocality({
    required String cityName,
    String countryHint = '',
  }) async {
    final name = cityName.trim();
    if (name.isEmpty || !isConfigured) return null;
    if (_quotaCircuitOpen) return null;
    if (!tryAcquirePlacesHttpPermit()) return null;
    try {
      final hint = countryHint.trim();
      final query = hint.isEmpty ? name : '$name $hint';
      final found = await _searchTextRaw(
        query: query,
        city: name,
        maxResults: 5,
        fieldMask:
            'places.id,places.displayName,places.formattedAddress,'
            'places.location,places.addressComponents,places.types',
        includedType: 'locality',
      );
      for (final row in found.places) {
        final hit = GooglePlacesLocalityHit.tryParse(row);
        if (hit != null) return hit;
      }
      // Broaden if includedType filtered everything out.
      final broad = await _searchTextRaw(
        query: query,
        city: name,
        maxResults: 5,
        fieldMask:
            'places.id,places.displayName,places.formattedAddress,'
            'places.location,places.addressComponents,places.types',
      );
      for (final row in broad.places) {
        final hit = GooglePlacesLocalityHit.tryParse(row);
        if (hit != null) return hit;
      }
    } catch (e) {
      debugPrint('[GP] Places resolveLocality error: $e');
    } finally {
      releasePlacesHttpPermit();
    }
    return null;
  }

  /// Live city suggestions for the Explore location search field.
  Future<List<GooglePlacesLocalityHit>> suggestLocalities({
    required String query,
    int maxResults = 6,
  }) async {
    final q = query.trim();
    if (q.length < 2 || !isConfigured) return const [];
    if (_quotaCircuitOpen) return const [];
    if (!tryAcquirePlacesHttpPermit()) return const [];
    try {
      final found = await _searchTextRaw(
        query: q,
        city: q,
        maxResults: maxResults.clamp(1, 10),
        fieldMask:
            'places.id,places.displayName,places.formattedAddress,'
            'places.location,places.addressComponents,places.types',
        includedType: 'locality',
      );
      final out = <GooglePlacesLocalityHit>[];
      final seen = <String>{};
      for (final row in found.places) {
        final hit = GooglePlacesLocalityHit.tryParse(row);
        if (hit == null) continue;
        if (!seen.add(hit.placeId)) continue;
        out.add(hit);
        if (out.length >= maxResults) break;
      }
      if (out.isNotEmpty) return out;
      // Second pass: administrative areas (regions / counties), still not
      // businesses. Never fall back to an untyped text search — that returns
      // restaurants, salons, and street names.
      final admin = await _searchTextRaw(
        query: q,
        city: q,
        maxResults: maxResults.clamp(1, 10),
        fieldMask:
            'places.id,places.displayName,places.formattedAddress,'
            'places.location,places.addressComponents,places.types',
        includedType: 'administrative_area_level_1',
      );
      for (final row in admin.places) {
        final hit = GooglePlacesLocalityHit.tryParse(row);
        if (hit == null) continue;
        if (!seen.add(hit.placeId)) continue;
        out.add(hit);
        if (out.length >= maxResults) break;
      }
      return out;
    } catch (e) {
      debugPrint('[GP] Places suggestLocalities error: $e');
      return const [];
    } finally {
      releasePlacesHttpPermit();
    }
  }

  /// Reverse-geocode device coordinates into a Places locality.
  Future<GooglePlacesLocalityHit?> resolveLocalityFromLatLng({
    required double latitude,
    required double longitude,
  }) async {
    if (!isConfigured) return null;
    if (_quotaCircuitOpen) return null;
    if (!tryAcquirePlacesHttpPermit()) return null;
    try {
      final found = await _searchNearbyRaw(
        latitude: latitude,
        longitude: longitude,
        radiusMeters: 12000,
        maxResults: 8,
        fieldMask:
            'places.id,places.displayName,places.formattedAddress,'
            'places.location,places.addressComponents,places.types',
        includedTypes: const ['locality', 'administrative_area_level_2'],
      );
      for (final row in found) {
        final hit = GooglePlacesLocalityHit.tryParse(row);
        if (hit != null) return hit;
      }
      // Fallback: text search near the pin.
      final pinQuery =
          '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';
      final text = await _searchTextRaw(
        query: pinQuery,
        city: pinQuery,
        maxResults: 5,
        fieldMask:
            'places.id,places.displayName,places.formattedAddress,'
            'places.location,places.addressComponents,places.types',
        includedType: 'locality',
        locationBias: (lat: latitude, lng: longitude, radiusMeters: 25000),
      );
      for (final row in text.places) {
        final hit = GooglePlacesLocalityHit.tryParse(row);
        if (hit != null) return hit;
      }
    } catch (e) {
      debugPrint('[GP] Places resolveLocalityFromLatLng error: $e');
    } finally {
      releasePlacesHttpPermit();
    }
    return null;
  }

  Future<GooglePlacesResult?> lookupPlaceId({
    required String placeId,
    required String city,
  }) {
    final id = _normalizePlaceId(placeId);
    if (id.isEmpty || !isConfigured) return Future.value(null);
    if (_quotaCircuitOpen) return Future.value(null);
    final key = 'placeId|$id';
    final pending = _placeIdCache[key];
    if (pending != null) return pending;
    if (!tryAcquirePlacesHttpPermit()) return Future.value(null);
    final fut = _lookupPlaceIdUncached(
      placeId: id,
      city: city,
    ).whenComplete(releasePlacesHttpPermit);
    _placeIdCache[key] = fut;
    return fut;
  }

  /// Resolves a clinic by free-text name + city to a verified profile.
  /// Returns `null` when the API key is missing or the clinic isn't found.
  ///
  /// [includeReviews] is only for clinic profile/detail. Compare enrich uses
  /// the cheap field mask so we do not bill Atmosphere reviews + Contact hours
  /// on every card.
  Future<GooglePlacesResult?> lookupClinic({
    required String clinicName,
    required String city,
    bool includeReviews = false,
  }) {
    if (!isConfigured) return Future.value(null);
    if (_quotaCircuitOpen) return Future.value(null);
    final key = 'places|${clinicName.trim().toLowerCase()}|'
        '${city.trim().toLowerCase()}|${includeReviews ? 'full' : 'lite'}';
    final expires = _unratedCacheUntil[key];
    if (expires != null && !_now().isBefore(expires)) {
      _unratedCacheUntil.remove(key);
      _cache.remove(key);
    }
    final hit = _cache[key];
    if (hit != null) return hit;
    if (!tryAcquirePlacesHttpPermit()) return Future.value(null);
    // Single chained Future: a separate onError listener on the same Future
    // causes Flutter's test zone to treat the error as unhandled even when
    // the caller awaits/catches it. Keep cache eviction in this chain.
    final fut = () async {
      try {
        final value = await _lookupClinicUncached(
          clinicName: clinicName,
          city: city,
          includeReviews: includeReviews,
        );
        if (value == null || value.rating <= 0) {
          // Genuine misses / businesses without ratings are not transient
          // HTTP failures. Repeated tab builds should not immediately retry
          // the same paid lookup; allow recovery after a short cooldown.
          _unratedCacheUntil[key] = _now().add(_unratedCacheTtl);
        } else {
          _unratedCacheUntil.remove(key);
        }
        return value;
      } catch (_) {
        _unratedCacheUntil.remove(key);
        _cache.remove(key);
        rethrow;
      } finally {
        releasePlacesHttpPermit();
      }
    }();
    _cache[key] = fut;
    return fut;
  }

  Future<GooglePlacesResult?> _lookupClinicUncached({
    required String clinicName,
    required String city,
    required bool includeReviews,
  }) async {
    if (!isConfigured) return null;

    final found = await _searchTextRaw(
      query: '$clinicName $city',
      city: city,
      maxResults: 1,
      // Compare needs identity + rating. Fetch them together so a second
      // Details request cannot discard a successful Text Search result.
      fieldMask: _liteFields.map((field) => 'places.$field').join(','),
      throwOnError: true,
    );
    if (found.places.isEmpty) return null;
    final placeId = _normalizePlaceId(found.places.first['id']);
    if (placeId.isEmpty) return null;

    final searchResult = GooglePlacesResult.fromJson(found.places.first, placeId: placeId);
    if (!includeReviews) return searchResult;

    try {
      final details = await _getPlace(
        placeId: placeId,
        city: city,
        includeReviews: includeReviews,
      );
      return details ?? searchResult;
    } catch (_) {
      return searchResult;
    }
  }

  Future<List<GooglePlacesSearchHit>> _searchTextUncached({
    required String query,
    required String city,
    required int maxResults,
  }) async {
    if (!isConfigured) return const [];
    final cap = maxResults < 1 ? 1 : (maxResults > 20 ? 20 : maxResults);
    try {
      final found = await _searchTextRaw(
        query: query,
        city: city,
        maxResults: cap,
        fieldMask: _searchHitFields.join(','),
      );
      final out = <GooglePlacesSearchHit>[];
      final seen = <String>{};
      for (final m in found.places) {
        if (out.length >= cap) break;
        final placeId = _normalizePlaceId(m['id']);
        final name = _displayName(m);
        if (placeId.isEmpty || name.isEmpty) continue;
        if (!seen.add(placeId)) continue;
        final loc = _asMap(m['location']);
        final types = ((m['types'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false);
        out.add(
          GooglePlacesSearchHit(
            placeId: placeId,
            name: name,
            address: (m['formattedAddress'] as String?)?.trim() ?? '',
            rating: (m['rating'] is num) ? (m['rating'] as num).toDouble() : 0,
            reviewsTotal: (m['userRatingCount'] as num?)?.toInt() ?? 0,
            lat: (loc['latitude'] is num)
                ? (loc['latitude'] as num).toDouble()
                : 0,
            lng: (loc['longitude'] is num)
                ? (loc['longitude'] as num).toDouble()
                : 0,
            types: types,
          ),
        );
      }
      return out;
    } catch (e) {
      debugPrint('[GP] Places searchText error: $e');
      return const [];
    }
  }

  Future<GooglePlacesResult?> _lookupPlaceIdUncached({
    required String placeId,
    required String city,
  }) async {
    if (!isConfigured) return null;
    try {
      return _getPlace(placeId: placeId, city: city, includeReviews: false);
    } catch (e) {
      debugPrint('[GP] Places getPlace error: $e');
      return null;
    }
  }

  Future<({List<Map<String, Object?>> places, String nextPageToken})>
  _searchTextRaw({
    required String query,
    required String city,
    required int maxResults,
    required String fieldMask,
    String? includedType,
    bool throwOnError = false,
    ({double lat, double lng, double radiusMeters})? locationBias,
  }) async {
    // New launches blocked; in-flight public callers already hold a permit.
    if (_quotaCircuitOpen && _inFlightHttp <= 0) {
      return (places: const <Map<String, Object?>>[], nextPageToken: '');
    }
    final cap = maxResults < 1 ? 1 : (maxResults > 20 ? 20 : maxResults);
    final body = <String, Object?>{
      'textQuery': query,
      'maxResultCount': cap,
      'languageCode': _languageForCity(city),
    };
    final type = includedType?.trim() ?? '';
    if (type.isNotEmpty) body['includedType'] = type;
    if (locationBias != null) {
      body['locationBias'] = {
        'circle': {
          'center': {
            'latitude': locationBias.lat,
            'longitude': locationBias.lng,
          },
          'radius': locationBias.radiusMeters,
        },
      };
    }
    final res = await _client.post(
      Uri.https(_host, '/v1/places:searchText'),
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': _apiKey,
        'X-Goog-FieldMask': fieldMask,
      },
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 8));
    final json = _decodeObject(res.body);
    if (res.statusCode < 200 ||
        res.statusCode >= 300 ||
        json['error'] != null) {
      _logPlacesError('searchText', res, json);
      if (throwOnError) {
        final status = _asMap(json['error'])['status'] ?? 'HTTP_${res.statusCode}';
        throw StateError('Places lookup failed: $status');
      }
      return (places: const <Map<String, Object?>>[], nextPageToken: '');
    }
    final rows = (json['places'] as List?) ?? const [];
    return (
      places: [
        for (final raw in rows)
          if (raw is Map) raw.cast<String, Object?>(),
      ],
      nextPageToken: (json['nextPageToken'] as String?)?.trim() ?? '',
    );
  }

  Future<List<Map<String, Object?>>> _searchNearbyRaw({
    required double latitude,
    required double longitude,
    required double radiusMeters,
    required int maxResults,
    required String fieldMask,
    List<String> includedTypes = const [],
  }) async {
    if (_quotaCircuitOpen && _inFlightHttp <= 0) return const [];
    final cap = maxResults < 1 ? 1 : (maxResults > 20 ? 20 : maxResults);
    final body = <String, Object?>{
      'maxResultCount': cap,
      'locationRestriction': {
        'circle': {
          'center': {'latitude': latitude, 'longitude': longitude},
          'radius': radiusMeters,
        },
      },
    };
    if (includedTypes.isNotEmpty) {
      body['includedTypes'] = includedTypes;
    }
    final res = await _client.post(
      Uri.https(_host, '/v1/places:searchNearby'),
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': _apiKey,
        'X-Goog-FieldMask': fieldMask,
      },
      body: jsonEncode(body),
    );
    final json = _decodeObject(res.body);
    if (res.statusCode < 200 ||
        res.statusCode >= 300 ||
        json['error'] != null) {
      _logPlacesError('searchNearby', res, json);
      return const [];
    }
    final rows = (json['places'] as List?) ?? const [];
    return [
      for (final raw in rows)
        if (raw is Map) raw.cast<String, Object?>(),
    ];
  }

  Future<GooglePlacesResult?> _getPlace({
    required String placeId,
    required String city,
    required bool includeReviews,
  }) async {
    final id = _normalizePlaceId(placeId);
    if (id.isEmpty) return null;
    // Allow continuation for the in-flight permit holder after breaker opens.
    if (_quotaCircuitOpen && _inFlightHttp <= 0) return null;
    final fields = includeReviews ? _fullFields : _liteFields;
    final res = await _client.get(
      Uri.https(_host, '/v1/places/$id', {
        'languageCode': _languageForCity(city),
      }),
      headers: {
        'X-Goog-Api-Key': _apiKey,
        'X-Goog-FieldMask': fields.join(','),
      },
    );
    final json = _decodeObject(res.body);
    if (res.statusCode < 200 ||
        res.statusCode >= 300 ||
        json['error'] != null) {
      _logPlacesError('getPlace', res, json);
      return null;
    }
    if (json.isEmpty) return null;
    return GooglePlacesResult.fromJson(json, placeId: id);
  }

  /// Best-effort Google language hint based on city name (RO / TR / ES / FR / IT / DE / EN).
  String _languageForCity(String city) {
    final c = city.toLowerCase();
    bool any(List<String> tokens) => tokens.any((t) => c.contains(t));
    if (any(const [
      'bucur',
      'cluj',
      'iași',
      'iasi',
      'timi',
      'constan',
      'sibiu',
      'brașov',
      'brasov',
      'chisinau',
      'chișinău',
      'moldova',
    ])) {
      return 'ro';
    }
    if (any(const ['istanbul', 'ankara', 'izmir', 'antaly'])) return 'tr';
    if (any(const [
      'madrid',
      'barcelona',
      'valencia',
      'valència',
      'sevilla',
      'malaga',
      'málaga',
    ]))
      return 'es';
    if (any(const ['paris', 'lyon', 'marseille', 'nice', 'bordeaux']))
      return 'fr';
    if (any(const [
      'milano',
      'milan',
      'roma',
      'rome',
      'napoli',
      'naples',
      'firenze',
      'florence',
    ]))
      return 'it';
    if (any(const [
      'berlin',
      'münchen',
      'munich',
      'hamburg',
      'frankfurt',
      'köln',
      'cologne',
    ]))
      return 'de';
    return 'en';
  }

  static String _normalizePlaceId(Object? raw) {
    var id = (raw is String ? raw : raw?.toString() ?? '').trim();
    if (id.startsWith('places/')) id = id.substring('places/'.length);
    return id;
  }

  static String _displayName(Map<String, Object?> json) {
    final name = json['displayName'];
    if (name is Map) {
      return ((name['text'] as String?) ?? '').trim();
    }
    return ((json['name'] as String?) ?? '').trim();
  }

  static Map<String, Object?> _asMap(Object? raw) {
    if (raw is Map) return raw.cast<String, Object?>();
    return const {};
  }

  static Map<String, Object?> _decodeObject(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } catch (_) {}
    return const {};
  }

  static void _logPlacesError(
    String op,
    http.Response res,
    Map<String, Object?> json,
  ) {
    final err = _asMap(json['error']);
    final status =
        (json['status'] as String?) ?? (err['status'] as String?) ?? '';
    final msg =
        (json['error_message'] as String?) ?? (err['message'] as String?) ?? '';
    debugPrint(
      '[GP] Places $op failed · HTTP ${res.statusCode} · $status · $msg',
    );
    _tripQuotaCircuit(
      op: op,
      statusCode: res.statusCode,
      status: status,
      message: msg,
    );
  }

  static String _readKey() {
    final fromDefine = const String.fromEnvironment(
      'GOOGLE_PLACES_API_KEY',
    ).trim();
    if (fromDefine.isNotEmpty) return fromDefine;
    return (dotenv.env['GOOGLE_PLACES_API_KEY'] ?? '').trim();
  }
}

class GooglePlacesSearchHit {
  const GooglePlacesSearchHit({
    required this.placeId,
    required this.name,
    required this.address,
    required this.rating,
    required this.reviewsTotal,
    required this.lat,
    required this.lng,
    required this.types,
  });

  final String placeId;
  final String name;
  final String address;
  final double rating;
  final int reviewsTotal;
  final double lat;
  final double lng;
  final List<String> types;
}

/// Locality hit from Places text search — wires Explore city picker to Maps.
class GooglePlacesLocalityHit {
  const GooglePlacesLocalityHit({
    required this.placeId,
    required this.name,
    required this.formattedAddress,
    required this.lat,
    required this.lng,
    required this.countryCode,
    required this.adminArea,
    required this.types,
  });

  final String placeId;
  final String name;
  final String formattedAddress;
  final double lat;
  final double lng;
  final String countryCode;
  final String adminArea;
  final List<String> types;

  static GooglePlacesLocalityHit? tryParse(Map<String, Object?> json) {
    final types = ((json['types'] as List?) ?? const [])
        .whereType<String>()
        .toList(growable: false);
    final isLocality = types.any(
      (t) =>
          t == 'locality' ||
          t == 'administrative_area_level_1' ||
          t == 'administrative_area_level_2' ||
          t == 'postal_town' ||
          t == 'colloquial_area',
    );
    // Reject businesses / streets / POIs even when they carry a country code.
    final isBusinessOrStreet = types.any(
      (t) =>
          t == 'establishment' ||
          t == 'point_of_interest' ||
          t == 'premise' ||
          t == 'street_address' ||
          t == 'route' ||
          t == 'subway_station' ||
          t == 'transit_station' ||
          t == 'restaurant' ||
          t == 'food' ||
          t == 'store' ||
          t == 'shopping_mall' ||
          t == 'lodging' ||
          t == 'spa' ||
          t == 'beauty_salon' ||
          t == 'hair_care' ||
          t == 'health' ||
          t == 'doctor' ||
          t == 'hospital' ||
          t == 'dentist' ||
          t == 'physiotherapist',
    );
    String countryCode = '';
    String adminArea = '';
    final components =
        (json['addressComponents'] as List?) ??
        (json['address_components'] as List?) ??
        const [];
    for (final raw in components.whereType<Map>()) {
      final m = raw.cast<String, Object?>();
      final t = ((m['types'] as List?) ?? const [])
          .whereType<String>()
          .toList();
      final long =
          (m['longText'] as String?)?.trim() ??
          (m['long_name'] as String?)?.trim() ??
          '';
      final short =
          (m['shortText'] as String?)?.trim() ??
          (m['short_name'] as String?)?.trim() ??
          '';
      if (t.contains('country')) {
        countryCode = short.toUpperCase();
      }
      if (t.contains('administrative_area_level_1') && adminArea.isEmpty) {
        adminArea = long;
      }
    }
    // Locality / admin area only — never accept a restaurant just because it
    // has addressComponents.country.
    if (!isLocality || isBusinessOrStreet) return null;
    if (countryCode.isEmpty && types.isEmpty) return null;

    final idRaw = json['id'] ?? json['name'];
    var placeId = (idRaw is String ? idRaw : idRaw?.toString() ?? '').trim();
    if (placeId.startsWith('places/')) {
      placeId = placeId.substring('places/'.length);
    }
    if (placeId.isEmpty) return null;

    final display = json['displayName'];
    final name = display is Map
        ? ((display['text'] as String?) ?? '').trim()
        : ((json['name'] as String?) ?? '').trim();
    final loc = (json['location'] as Map?)?.cast<String, Object?>() ?? const {};
    final lat = (loc['latitude'] as num?)?.toDouble() ?? 0.0;
    final lng = (loc['longitude'] as num?)?.toDouble() ?? 0.0;
    if (lat.abs() < 0.01 && lng.abs() < 0.01) return null;

    return GooglePlacesLocalityHit(
      placeId: placeId,
      name: name.isNotEmpty ? name : placeId,
      formattedAddress:
          (json['formattedAddress'] as String?)?.trim() ??
          (json['formatted_address'] as String?)?.trim() ??
          '',
      lat: lat,
      lng: lng,
      countryCode: countryCode,
      adminArea: adminArea,
      types: types,
    );
  }
}

class GooglePlacesResult {
  const GooglePlacesResult({
    required this.placeId,
    required this.name,
    required this.address,
    required this.phone,
    required this.website,
    required this.openingHoursLines,
    required this.isOpenNow,
    required this.rating,
    required this.reviewsTotal,
    required this.lat,
    required this.lng,
    required this.googleMapsUrl,
    required this.area,
    required this.reviews,
    required this.editorialSummary,
  });

  final String placeId;
  final String name;
  final String address;
  final String phone;
  final String website;
  final List<String> openingHoursLines;
  final bool isOpenNow;
  final double rating;
  final int reviewsTotal;
  final double lat;
  final double lng;
  final String googleMapsUrl;

  /// Sublocality / district extracted from address components when present.
  final String area;
  final List<GooglePlacesReview> reviews;
  final String editorialSummary;

  /// Flat one-line representation of opening hours, e.g. "Mon–Sat 9:00–19:00".
  String get openingHoursOneLine {
    if (openingHoursLines.isEmpty) return '';
    if (openingHoursLines.length == 1) return openingHoursLines.first;
    // Pick today's first; otherwise just join the first 2.
    return openingHoursLines.first;
  }

  factory GooglePlacesResult.fromJson(
    Map<String, Object?> json, {
    required String placeId,
  }) {
    final geometry =
        (json['geometry'] as Map?)?.cast<String, Object?>() ?? const {};
    final locLegacy =
        (geometry['location'] as Map?)?.cast<String, Object?>() ?? const {};
    final locNew =
        (json['location'] as Map?)?.cast<String, Object?>() ?? const {};
    final hours =
        (json['currentOpeningHours'] as Map?)?.cast<String, Object?>() ??
        (json['regularOpeningHours'] as Map?)?.cast<String, Object?>() ??
        (json['current_opening_hours'] as Map?)?.cast<String, Object?>() ??
        (json['opening_hours'] as Map?)?.cast<String, Object?>() ??
        const {};
    final weekday =
        (hours['weekdayDescriptions'] as List?) ??
        (hours['weekday_text'] as List?) ??
        const [];
    final phoneIntl =
        (json['internationalPhoneNumber'] as String?)?.trim() ??
        (json['international_phone_number'] as String?)?.trim() ??
        '';
    final phoneLocal =
        (json['nationalPhoneNumber'] as String?)?.trim() ??
        (json['formatted_phone_number'] as String?)?.trim() ??
        '';
    final summary =
        (json['editorialSummary'] as Map?)?.cast<String, Object?>() ??
        (json['editorial_summary'] as Map?)?.cast<String, Object?>() ??
        const {};

    final reviewsRaw = (json['reviews'] as List?) ?? const [];
    final parsedReviews = reviewsRaw
        .whereType<Map>()
        .map((m) => GooglePlacesReview.fromJson(m.cast<String, Object?>()))
        .toList();
    parsedReviews.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    String area = '';
    final components =
        (json['addressComponents'] as List?) ??
        (json['address_components'] as List?) ??
        const [];
    for (final comp in components.whereType<Map>()) {
      final m = comp.cast<String, Object?>();
      final types = ((m['types'] as List?) ?? const [])
          .whereType<String>()
          .toList();
      if (types.contains('sublocality') ||
          types.contains('sublocality_level_1') ||
          types.contains('neighborhood')) {
        area =
            (m['longText'] as String?)?.trim() ??
            (m['long_name'] as String?)?.trim() ??
            '';
        if (area.isNotEmpty) break;
      }
    }

    final display = json['displayName'];
    final name = display is Map
        ? ((display['text'] as String?) ?? '').trim()
        : ((json['name'] as String?)?.trim() ?? '');

    final lat = (locNew['latitude'] is num)
        ? (locNew['latitude'] as num).toDouble()
        : (locLegacy['lat'] is num)
        ? (locLegacy['lat'] as num).toDouble()
        : 0.0;
    final lng = (locNew['longitude'] is num)
        ? (locNew['longitude'] as num).toDouble()
        : (locLegacy['lng'] is num)
        ? (locLegacy['lng'] as num).toDouble()
        : 0.0;

    return GooglePlacesResult(
      placeId: placeId,
      name: name,
      address:
          (json['formattedAddress'] as String?)?.trim() ??
          (json['formatted_address'] as String?)?.trim() ??
          '',
      phone: phoneIntl.isNotEmpty ? phoneIntl : phoneLocal,
      website:
          (json['websiteUri'] as String?)?.trim() ??
          (json['website'] as String?)?.trim() ??
          '',
      openingHoursLines: weekday.whereType<String>().toList(growable: false),
      isOpenNow:
          (hours['openNow'] as bool?) ?? (hours['open_now'] as bool?) ?? false,
      rating: (json['rating'] is num)
          ? (json['rating'] as num).toDouble()
          : 0.0,
      reviewsTotal:
          (json['userRatingCount'] as num?)?.toInt() ??
          (json['user_ratings_total'] as num?)?.toInt() ??
          0,
      lat: lat,
      lng: lng,
      googleMapsUrl:
          (json['googleMapsUri'] as String?)?.trim() ??
          (json['url'] as String?)?.trim() ??
          '',
      area: area,
      reviews: parsedReviews,
      editorialSummary:
          (summary['overview'] as String?)?.trim() ??
          (summary['text'] as String?)?.trim() ??
          '',
    );
  }
}

class GooglePlacesReview {
  const GooglePlacesReview({
    required this.authorName,
    required this.rating,
    required this.text,
    required this.relativeTime,
    required this.timestamp,
  });

  final String authorName;
  final double rating;
  final String text;

  /// Localized "3 days ago" string from the API.
  final String relativeTime;

  /// Unix-epoch timestamp the review was published.
  final int timestamp;

  String get isoDate {
    if (timestamp <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(
      timestamp * 1000,
      isUtc: true,
    );
    return dt.toIso8601String().substring(0, 10);
  }

  String get initials {
    final parts = authorName
        .trim()
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    return parts.take(2).map((p) => p[0]).join().toUpperCase();
  }

  factory GooglePlacesReview.fromJson(Map<String, Object?> json) {
    final author =
        (json['authorAttribution'] as Map?)?.cast<String, Object?>() ??
        const {};
    final textRaw = json['text'];
    final text = textRaw is Map
        ? ((textRaw['text'] as String?) ?? '')
        : ((textRaw as String?) ?? '');
    var timestamp = (json['time'] as num?)?.toInt() ?? 0;
    if (timestamp <= 0) {
      final publishTime = (json['publishTime'] as String?) ?? '';
      if (publishTime.isNotEmpty) {
        final parsed = DateTime.tryParse(publishTime);
        if (parsed != null) {
          timestamp = parsed.millisecondsSinceEpoch ~/ 1000;
        }
      }
    }
    return GooglePlacesReview(
      authorName:
          (author['displayName'] as String?)?.trim() ??
          (json['author_name'] as String?)?.trim() ??
          '',
      rating: (json['rating'] is num)
          ? (json['rating'] as num).toDouble()
          : 0.0,
      text: text.trim(),
      relativeTime:
          (json['relativePublishTimeDescription'] as String?)?.trim() ??
          (json['relative_time_description'] as String?)?.trim() ??
          '',
      timestamp: timestamp,
    );
  }
}
