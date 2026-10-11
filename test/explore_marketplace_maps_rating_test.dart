import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../lib/services/explore_clinic_identity.dart';
import '../lib/services/explore_place_cache_store.dart';
import '../lib/services/google_places_service.dart';
import '../lib/services/openai_service.dart';
import 'explore_verified_card_titles_test.dart' as fixtures;

class _NoFirestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Rating tests must not use Firestore');
}

class _PlaceCache implements ExplorePlaceCacheStore {
  final entries = <String, ExplorePlaceCacheEntry>{};
  String key(String city, String name) => '$city|$name';

  @override
  Future<ExplorePlaceCacheEntry?> lookupAny({required String city,
    required List<String> clinicNames}) async {
    for (final name in clinicNames) {
      final entry = entries[key(city, name)];
      if (entry != null) return entry;
    }
    return null;
  }

  @override
  ExplorePlaceCacheEntry? peekMemory({required String city,
    required String clinicName}) => entries[key(city, clinicName)];

  @override
  void rememberMiss({required String city, required String clinicName}) {
    entries[key(city, clinicName)] = ExplorePlaceCacheEntry.miss();
  }

  @override
  Future<void> put({required String city, required String clinicName,
    required double rating, required int reviews, required String websiteHost,
    required double lat, required double lng, String mapsName = ''}) async {
    entries[key(city, clinicName)] = ExplorePlaceCacheEntry(matched: true,
      rating: rating, reviews: reviews, websiteHost: websiteHost,
      mapsName: mapsName, lat: lat, lng: lng, fetchedAt: DateTime.now(),
      memoryOnly: true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('$invocation');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    dotenv.testLoad(fileInput: '');
    GooglePlacesService.resetQuotaCircuitBreaker();
  });

  OpenAIClinic clinic(String name) => fixtures.clinic(name: name,
    city: 'Istanbul', procedure: 'Fillers', canonical: 'filler',
    rawTitle: 'Fillers injection', amount: 350, currency: 'USD').copyWith(
      area: 'Istanbul · us-uk.bookimed.com', sourceType: 'marketplace',
      priceSourceUrl: 'https://us-uk.bookimed.com/clinic/aster/',
      sourceLocationText: 'Provider locality: Istanbul');

  OpenAIComparisonResult comparison(OpenAIClinic row) => OpenAIComparisonResult(
    city: 'Istanbul', topic: 'Fillers', topicType: OpenAISearchItemType.procedure,
    summary: '', rangeLabel: '', mapCenter: row.coord, clinics: [row]);

  test('marketplace rating survives official domain mismatch and cache reuse', () async {
    final queries = <String>[];
    final cache = _PlaceCache();
    final client = MockClient((request) async {
      expect(request.url.host, 'places.googleapis.com');
      queries.add((jsonDecode(request.body) as Map)['textQuery'] as String);
      return http.Response(jsonEncode({'places': [{
        'id': 'aster-maps', 'displayName': {'text': 'Aster Clinique'},
        'formattedAddress': 'Sisli, Istanbul, Turkey',
        'websiteUri': 'https://aster.example/',
        'rating': 4.6, 'userRatingCount': 125,
        'location': {'latitude': 41.05, 'longitude': 28.98},
        'types': ['medical_clinic'],
      }]}), 200);
    });
    addTearDown(client.close);
    final service = OpenAIService(client: client, apiKey: '', placesApiKey: '',
      places: GooglePlacesService(client: client, apiKey: 'test-key'),
      placeCache: cache, firestore: _NoFirestore());
    final original = clinic('Aster Hospital in Turkey');
    for (var i = 0; i < 2; i++) {
      final enriched = await service.backfillMissingClinicRatings(
        base: comparison(original), city: 'Istanbul', procedure: '', pill: 'Fillers');
      final row = enriched.clinics.single;
      expect(row.rating, 4.6);
      expect(row.reviews, 125);
      expect(row.name, 'Aster Clinique');
      expect(row.providerClinic, original.providerClinic);
      expect(row.priceMin, original.priceMin);
      expect(row.currency, original.currency);
      expect(row.priceSourceUrl, original.priceSourceUrl);
      expect(row.priceEvidenceText, original.priceEvidenceText);
      expect(row.priceExtractRevision, original.priceExtractRevision);
    }
    expect(queries, ['Aster Hospital Istanbul']);
    expect(cache.entries.values.single.websiteHost, 'aster.example');
  });

  test('wrong clinic or wrong city cannot supply a marketplace rating', () async {
    for (final (name, address, sourceName) in [
      ('Other Clinic', 'Istanbul, Turkey', 'Birch Clinic in Turkey'),
      ('Cypress Clinic', 'Ankara, Turkey', 'Cypress Clinic in Turkey'),
    ]) {
      final client = MockClient((_) async => http.Response(jsonEncode({'places': [{
        'id': 'wrong-maps', 'displayName': {'text': name},
        'formattedAddress': address, 'websiteUri': 'https://other.example/',
        'rating': 4.9, 'userRatingCount': 900, 'types': ['medical_clinic'],
      }]}), 200));
      addTearDown(client.close);
      final service = OpenAIService(client: client, apiKey: '', placesApiKey: '',
        places: GooglePlacesService(client: client, apiKey: 'test-key'),
        placeCache: _PlaceCache(), firestore: _NoFirestore());
      final original = clinic(sourceName);
      final enriched = await service.backfillMissingClinicRatings(
        base: comparison(original), city: 'Istanbul', procedure: '', pill: 'Fillers');
      expect(enriched.clinics.single.rating, 0);
      expect(enriched.clinics.single.priceMin, original.priceMin);
      expect(enriched.clinics.single.priceSourceUrl, original.priceSourceUrl);
    }
  });

  test('a matching provider name passes both live website checks', () async {
    final client = MockClient((_) async => http.Response(jsonEncode({'places': [{
      'id': 'maple-maps', 'displayName': {'text': 'Maple Medical Clinic'},
      'formattedAddress': 'Istanbul, Turkey',
      'websiteUri': 'https://maple.example/',
      'rating': 4.7, 'userRatingCount': 75, 'types': ['medical_clinic'],
    }]}), 200));
    addTearDown(client.close);
    final service = OpenAIService(client: client, apiKey: '', placesApiKey: '',
      places: GooglePlacesService(client: client, apiKey: 'test-key'),
      placeCache: _PlaceCache(), firestore: _NoFirestore());
    final original = clinic('Maple Medical Clinic');
    final result = await service.backfillMissingClinicRatings(
      base: comparison(original), city: 'Istanbul', procedure: '', pill: 'Fillers');
    expect(result.clinics.single.rating, 4.7);
    expect(result.clinics.single.reviews, 75);
    expect(result.clinics.single.priceSourceUrl, original.priceSourceUrl);
  });

  test('provider lookup normalizes platform suffixes, not distinctive names', () {
    expect(exploreMarketplaceProviderLookupName('Cedar Clinic in New Zealand'),
      'Cedar Clinic');
    expect(exploreMarketplaceProviderLookupName('Institute in Balance'),
      'Institute in Balance');
    expect(exploreMapsProviderIdentityMatches(sourceName: 'Dr. Alice Smith Clinic in Turkey',
      mapsName: 'Dr. Bob Smith', sourceHost: 'bookimed.com',
      mapsHost: 'bob.example', marketplace: true), isFalse);
  });
}
