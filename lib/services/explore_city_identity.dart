import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'explore_search_locale.dart';

/// Worldwide locality identity for Explore discovery / cache / Firestore keys.
///
/// Same display name in different countries must not collide
/// (Paris FR ≠ Paris TX; London UK ≠ London ON).
class ExploreCityIdentity {
  const ExploreCityIdentity({
    required this.cityId,
    required this.displayName,
    required this.canonicalName,
    this.localName = '',
    this.asciiName = '',
    this.adminArea = '',
    this.countryCode = '',
    this.countryName = '',
    this.latitude,
    this.longitude,
    this.placeId = '',
    this.languageCodes = const [],
    this.currencyCode = '',
    this.timezone = '',
    this.aliases = const [],
  });

  /// Stable unique id used in Firestore / cache / discovery locks.
  final String cityId;

  /// User-facing city label (may keep accents).
  final String displayName;

  /// Folded ascii-ish name for matching (`timisoara`, `sao paulo`).
  final String canonicalName;

  final String localName;
  final String asciiName;
  final String adminArea;
  final String countryCode;
  final String countryName;
  final double? latitude;
  final double? longitude;
  final String placeId;
  final List<String> languageCodes;
  final String currencyCode;
  final String timezone;
  final List<String> aliases;

  String get effectiveLocalName =>
      localName.trim().isNotEmpty ? localName.trim() : displayName.trim();

  String get effectiveAsciiName => asciiName.trim().isNotEmpty
      ? asciiName.trim()
      : foldExploreCityText(displayName);

  /// Coverage / discovery / comparison key — never name-only.
  /// Unresolved cities use an `unresolved_*` id that must not merge with peers.
  String get storageKey => cityId.trim();

  /// True when country + (placeId or coordinates) prove a worldwide locality.
  bool get isResolved {
    if (placeId.trim().isNotEmpty) return true;
    if (countryCode.trim().isEmpty) return false;
    if (latitude == null || longitude == null) return false;
    if (cityId.startsWith('unresolved_')) return false;
    return cityId.startsWith('place_') || cityId.startsWith('geo_');
  }

  bool get needsLocationResolution => !isResolved;

  /// True when [label] is the same locality via folded aliases.
  bool matchesAliasLabel(String label) {
    if (exploreCityLabelsAliasMatch(displayName, label, aliases: aliases)) {
      return true;
    }
    if (exploreCityLabelsAliasMatch(canonicalName, label, aliases: aliases)) {
      return true;
    }
    if (exploreCityLabelsAliasMatch(asciiName, label, aliases: aliases)) {
      return true;
    }
    return false;
  }

  /// Best-effort map / discovery coordinates when Places is unavailable.
  /// Not a clinic list — city centers only.
  static (double lat, double lng)? approxCoordinatesForCity(String city) {
    final key = foldExploreCityText(city).replaceAll(RegExp(r'[^a-z0-9]+'), '');
    const known = <String, (double, double)>{
      'london': (51.5072, -0.1276),
      'paris': (48.8566, 2.3522),
      'dubai': (25.2048, 55.2708),
      'istanbul': (41.0082, 28.9784),
      'ankara': (39.9334, 32.8597),
      'izmir': (38.4237, 27.1428),
      'antalya': (36.8969, 30.7133),
      'bursa': (40.1885, 29.0610),
      'bucharest': (44.4268, 26.1025),
      'bucuresti': (44.4268, 26.1025),
      'newyork': (40.7128, -74.0060),
      'miami': (25.7617, -80.1918),
      'losangeles': (34.0522, -118.2437),
      'milan': (45.4654, 9.1859),
      'milano': (45.4654, 9.1859),
      'seoul': (37.5665, 126.9780),
      'beirut': (33.8938, 35.5018),
      'moscow': (55.7558, 37.6173),
      'barcelona': (41.3851, 2.1734),
      'chisinau': (47.0105, 28.8638),
      'brasov': (45.6427, 25.5887),
      'timisoara': (45.7489, 21.2087),
      // Albania — "Tiranë" folds to tirane; English SERP uses tirana.
      'tirane': (41.3275, 19.8187),
      'tirana': (41.3275, 19.8187),
      'durres': (41.3231, 19.4414),
      'vlore': (40.4661, 19.4914),
      'shkoder': (42.0683, 19.5126),
      'pristina': (42.6629, 21.1655),
      'prishtina': (42.6629, 21.1655),
    };
    return known[key];
  }

  Map<String, Object?> toJson() => {
        'cityId': cityId,
        'displayName': displayName,
        'canonicalName': canonicalName,
        'localName': localName,
        'asciiName': asciiName,
        'adminArea': adminArea,
        'countryCode': countryCode,
        'countryName': countryName,
        'latitude': latitude,
        'longitude': longitude,
        'placeId': placeId,
        'languageCodes': languageCodes,
        'currencyCode': currencyCode,
        'timezone': timezone,
        'aliases': aliases,
      };

  factory ExploreCityIdentity.fromJson(Map<String, Object?> json) {
    double? numOrNull(Object? v) => v is num ? v.toDouble() : null;
    return ExploreCityIdentity(
      cityId: '${json['cityId'] ?? ''}'.trim(),
      displayName: '${json['displayName'] ?? ''}'.trim(),
      canonicalName: '${json['canonicalName'] ?? ''}'.trim(),
      localName: '${json['localName'] ?? ''}'.trim(),
      asciiName: '${json['asciiName'] ?? ''}'.trim(),
      adminArea: '${json['adminArea'] ?? ''}'.trim(),
      countryCode: '${json['countryCode'] ?? ''}'.trim().toUpperCase(),
      countryName: '${json['countryName'] ?? ''}'.trim(),
      latitude: numOrNull(json['latitude']),
      longitude: numOrNull(json['longitude']),
      placeId: '${json['placeId'] ?? ''}'.trim(),
      languageCodes: [
        for (final e in (json['languageCodes'] as List?) ?? const [])
          '$e'.trim(),
      ].where((e) => e.isNotEmpty).toList(),
      currencyCode: '${json['currencyCode'] ?? ''}'.trim().toUpperCase(),
      timezone: '${json['timezone'] ?? ''}'.trim(),
      aliases: [
        for (final e in (json['aliases'] as List?) ?? const []) '$e'.trim(),
      ].where((e) => e.isNotEmpty).toList(),
    );
  }

  /// Prefer Places locality id; else deterministic fallback from geography.
  static String buildCityId({
    String placeId = '',
    required String countryCode,
    String adminArea = '',
    required String canonicalName,
    double? latitude,
    double? longitude,
  }) {
    final pid = placeId.trim();
    if (pid.isNotEmpty) {
      final safe = pid.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      return 'place_$safe';
    }
    return deterministicFallbackCityId(
      countryCode: countryCode,
      adminArea: adminArea,
      canonicalName: canonicalName,
      latitude: latitude,
      longitude: longitude,
    );
  }

  /// Deterministic id when no provider locality id exists.
  ///
  /// Requires [countryCode] and coordinates. Without them the id is
  /// `unresolved_*` so it never collides with a resolved same-name city.
  static String deterministicFallbackCityId({
    required String countryCode,
    String adminArea = '',
    required String canonicalName,
    double? latitude,
    double? longitude,
  }) {
    final cc = countryCode.trim().toUpperCase();
    final admin = foldExploreCityText(adminArea).replaceAll(' ', '-');
    final name = foldExploreCityText(canonicalName).replaceAll(' ', '-');
    final hasGeo = latitude != null && longitude != null;
    final geo = hasGeo
        ? '${_geoBucket(latitude!)}_${_geoBucket(longitude!)}'
        : 'nogeo';
    final raw = '$cc|$admin|$name|$geo';
    final digest = sha1.convert(utf8.encode(raw)).toString().substring(0, 16);
    if (cc.isEmpty || !hasGeo) {
      return 'unresolved_$digest';
    }
    return 'geo_${cc}_$digest';
  }

  /// ~1.1 km buckets so minor GPS jitter does not fork city ids.
  static int _geoBucket(double deg) => (deg * 100).round();

  /// Resolve a typed city string into a worldwide identity.
  ///
  /// When country/coords/placeId are missing the result is [needsLocationResolution]
  /// and must not merge with an existing same-name city.
  static ExploreCityIdentity resolve({
    required String rawCity,
    String countryCode = '',
    String countryName = '',
    String adminArea = '',
    String placeId = '',
    double? latitude,
    double? longitude,
    String currencyCode = '',
    List<String> languageCodes = const [],
    List<String> aliases = const [],
  }) {
    final display = rawCity.trim();
    final canonical = exploreCanonicalCityKey(display);
    final ascii = foldExploreCityText(display);
    final id = buildCityId(
      placeId: placeId,
      countryCode: countryCode,
      adminArea: adminArea,
      canonicalName: canonical.isEmpty ? ascii : canonical,
      latitude: latitude,
      longitude: longitude,
    );
    final aliasSet = <String>{
      display,
      ascii,
      if (canonical.isNotEmpty) canonical,
      ...aliases,
    }..removeWhere((e) => e.trim().isEmpty);
    return ExploreCityIdentity(
      cityId: id,
      displayName: display.isEmpty ? ascii : display,
      canonicalName: canonical.isEmpty ? ascii : canonical,
      localName: display,
      asciiName: ascii,
      adminArea: adminArea.trim(),
      countryCode: countryCode.trim().toUpperCase(),
      countryName: countryName.trim(),
      latitude: latitude,
      longitude: longitude,
      placeId: placeId.trim(),
      languageCodes: languageCodes,
      currencyCode: currencyCode.trim().toUpperCase(),
      aliases: aliasSet.toList(),
    );
  }

  /// True when two identities refer to the same locality.
  /// Unresolved identities never merge with another city.
  static bool sameLocality(ExploreCityIdentity a, ExploreCityIdentity b) {
    if (!a.isResolved || !b.isResolved) return false;
    if (a.cityId.isNotEmpty && a.cityId == b.cityId) return true;
    if (a.placeId.isNotEmpty && a.placeId == b.placeId) return true;
    final sameCountry = a.countryCode.isNotEmpty &&
        a.countryCode == b.countryCode;
    final sameName = a.canonicalName.isNotEmpty &&
        a.canonicalName == b.canonicalName;
    if (sameCountry && sameName) {
      if (a.adminArea.isNotEmpty &&
          b.adminArea.isNotEmpty &&
          foldExploreCityText(a.adminArea) !=
              foldExploreCityText(b.adminArea)) {
        return false;
      }
      if (a.latitude != null &&
          a.longitude != null &&
          b.latitude != null &&
          b.longitude != null) {
        final d = _haversineKm(
          a.latitude!,
          a.longitude!,
          b.latitude!,
          b.longitude!,
        );
        return d <= 40;
      }
      return true;
    }
    return false;
  }

  static double haversineKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371.0;
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return 2 * r * math.asin(math.sqrt(a));
  }

  static double _haversineKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) =>
      haversineKm(lat1, lon1, lat2, lon2);

  static double _rad(double deg) => deg * math.pi / 180;
}

/// Legacy name-keyed docs may be reused only when geography matches [resolved].
bool exploreLegacyRecordMatchesResolvedCity({
  required ExploreCityIdentity resolved,
  String legacyCountryCode = '',
  String legacyAdminArea = '',
  String legacyCity = '',
  String legacyAddress = '',
  double? legacyLatitude,
  double? legacyLongitude,
}) {
  if (!resolved.isResolved) return false;
  final legacyCc = legacyCountryCode.trim().toUpperCase();
  final resolvedCc = resolved.countryCode.trim().toUpperCase();
  if (legacyCc.isNotEmpty &&
      resolvedCc.isNotEmpty &&
      legacyCc != resolvedCc) {
    return false;
  }

  final legacyAdmin = foldExploreCityText(legacyAdminArea);
  final resolvedAdmin = foldExploreCityText(resolved.adminArea);
  if (legacyAdmin.isNotEmpty &&
      resolvedAdmin.isNotEmpty &&
      legacyAdmin != resolvedAdmin &&
      legacyCc.isNotEmpty &&
      resolvedCc.isNotEmpty &&
      legacyCc == resolvedCc) {
    return false;
  }

  if (legacyLatitude != null &&
      legacyLongitude != null &&
      resolved.latitude != null &&
      resolved.longitude != null) {
    final d = ExploreCityIdentity.haversineKm(
      legacyLatitude,
      legacyLongitude,
      resolved.latitude!,
      resolved.longitude!,
    );
    return d <= 40;
  }

  if (legacyCc.isEmpty || resolvedCc.isEmpty) return false;
  final name = foldExploreCityText(resolved.canonicalName);
  final addr = foldExploreCityText('$legacyAddress $legacyCity');
  if (name.isEmpty) return false;
  final packed = name.replaceAll(RegExp(r'[\s_-]+'), '');
  if (addr.contains(name) ||
      addr.contains(packed) ||
      foldExploreCityText(legacyCity) == name) {
    return legacyCc == resolvedCc;
  }
  return false;
}

/// Coverage lifecycle for cityId + procedure discovery.
enum ExploreCoverageStatus {
  unknown,
  queued,
  running,
  partial,
  complete,
  thin,
  failed,
}

ExploreCoverageStatus exploreCoverageStatusFromWire(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'queued':
      return ExploreCoverageStatus.queued;
    case 'running':
      return ExploreCoverageStatus.running;
    case 'partial':
    case 'progressing':
    // Candidate-pool labels are NOT verification-complete.
    case 'healthy':
    case 'broad':
      return ExploreCoverageStatus.partial;
    case 'complete':
      return ExploreCoverageStatus.complete;
    case 'thin':
    case 'empty':
      return ExploreCoverageStatus.thin;
    case 'failed':
    case 'error':
      return ExploreCoverageStatus.failed;
    case 'unknown':
    case '':
      return ExploreCoverageStatus.unknown;
    default:
      return ExploreCoverageStatus.unknown;
  }
}

String exploreCoverageStatusWire(ExploreCoverageStatus s) => s.name;

/// Whether coverage is missing/thin enough to start worldwide discovery.
///
/// [verifiedVisibleCount] is the displayable verified price-card count.
/// Candidate pool size alone must never mark a city "done".
bool exploreCoverageNeedsDiscovery({
  ExploreCoverageStatus? status,
  int? candidateCount,
  int? verifiedVisibleCount,
  bool coverageDocumentExists = false,
  int visibleTarget = 4,
}) {
  if (verifiedVisibleCount != null &&
      verifiedVisibleCount < visibleTarget) {
    return true;
  }
  if (!coverageDocumentExists &&
      candidateCount == null &&
      (status == null || status == ExploreCoverageStatus.unknown)) {
    return true;
  }
  final s = status ?? ExploreCoverageStatus.unknown;
  if (s == ExploreCoverageStatus.unknown ||
      s == ExploreCoverageStatus.failed ||
      s == ExploreCoverageStatus.thin ||
      s == ExploreCoverageStatus.partial ||
      s == ExploreCoverageStatus.queued ||
      s == ExploreCoverageStatus.running) {
    return true;
  }
  if (candidateCount != null &&
      candidateCount < kExploreMinimumCandidateCoverage) {
    return true;
  }
  return false;
}

/// Soft floor before a city/procedure is considered "covered" for discovery.
const kExploreMinimumCandidateCoverage = 15;
