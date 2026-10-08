import 'dart:async';

import 'explore_city_identity.dart';
import 'explore_search_locale.dart';
import 'google_places_service.dart';
import 'openai_service.dart';

/// Resolves a typed / Places locality into [ExploreCityIdentity].
abstract class CityResolver {
  Future<ExploreCityIdentity?> resolve({
    required String rawCity,
    String countryHint = '',
  });
}

/// Discovers clinic candidates for a city + procedure (identity only).
abstract class ClinicDiscoveryProvider {
  Future<List<OpenAIClinic>> discoverClinics({
    required ExploreCityIdentity city,
    required String procedure,
    int limit = 30,
  });
}

/// Web/SERP search that returns candidate URLs — never price evidence.
abstract class SearchProvider {
  Future<List<({String title, String url, String snippet})>> search({
    required String query,
    required ExploreCityIdentity city,
    int limit = 10,
  });
}

/// Fetches official page HTML/markdown for extraction.
abstract class PageRetrievalProvider {
  Future<({String html, String markdown, String finalUrl})?> fetchPage({
    required String url,
    required ExploreCityIdentity city,
  });
}

/// Deterministic price extraction from official HTML.
abstract class PriceExtractionProvider {
  Future<List<Map<String, Object?>>> extract({
    required String html,
    required String sourceUrl,
    required String procedure,
  });
}

/// Evidence lock / relation / sanity gate before UI + Firestore.
abstract class PriceVerificationProvider {
  Future<OpenAIClinic?> verify({
    required OpenAIClinic candidate,
    required ExploreCityIdentity city,
    required String procedure,
  });
}

/// Default city resolver: structured identity without a paid Places round-trip.
class DefaultCityResolver implements CityResolver {
  @override
  Future<ExploreCityIdentity?> resolve({
    required String rawCity,
    String countryHint = '',
  }) async {
    final t = rawCity.trim();
    if (t.isEmpty) return null;
    final cc = countryHint.trim().isNotEmpty
        ? countryHint.trim().toUpperCase()
        : exploreCountryCodeForCity(t);
    return ExploreCityIdentity.resolve(
      rawCity: t,
      countryCode: cc,
    );
  }
}

/// Google Places locality resolver — preferred for Explore location picker.
class PlacesCityResolver implements CityResolver {
  PlacesCityResolver({GooglePlacesService? places})
      : _places = places ?? GooglePlacesService();

  final GooglePlacesService _places;

  @override
  Future<ExploreCityIdentity?> resolve({
    required String rawCity,
    String countryHint = '',
  }) async {
    final t = rawCity.trim();
    if (t.isEmpty) return null;
    final lower = t.toLowerCase();
    if (lower == 'worldwide' || lower == 'international') {
      return ExploreCityIdentity.resolve(rawCity: 'Worldwide');
    }
    final hint = countryHint.trim().isNotEmpty
        ? countryHint.trim().toUpperCase()
        : exploreCountryCodeForCity(t);
    try {
      final hit = await _places
          .resolveLocality(cityName: t, countryHint: hint)
          .timeout(const Duration(seconds: 4));
      if (hit != null) {
        return ExploreCityIdentity.resolve(
          rawCity: hit.name.isNotEmpty ? hit.name : t,
          countryCode: hit.countryCode.isNotEmpty ? hit.countryCode : hint,
          adminArea: hit.adminArea,
          placeId: hit.placeId,
          latitude: hit.lat,
          longitude: hit.lng,
        );
      }
    } catch (_) {/* fall through */}
    final approx = ExploreCityIdentity.approxCoordinatesForCity(t);
    return ExploreCityIdentity.resolve(
      rawCity: t,
      countryCode: hint,
      latitude: approx?.$1,
      longitude: approx?.$2,
    );
  }
}
