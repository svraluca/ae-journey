import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_comparison_session.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_price_verification.dart';
import 'package:glowpass/services/explore_procedure_relation.dart';
import 'package:glowpass/services/google_places_service.dart';
import 'package:glowpass/services/openai_service.dart';

OpenAIClinic _fillerCard({
  required String name,
  required String rawProcedure,
  required String sourceUrl,
  String relation = 'variant',
}) {
  return OpenAIClinic(
    rank: 1,
    name: name,
    area: 'clinic.example · src:$sourceUrl',
    distanceMi: 1,
    rating: 4.5,
    reviews: 20,
    priceGbp: 250,
    priceMin: 250,
    priceMax: 250,
    priceLabel: '250 EUR',
    currency: 'EUR',
    brand: 'dermal filler',
    badge: '',
    badgeVariant: 'mid',
    coord: const OpenAICoord(41.3275, 19.8187),
    hasProcedure: true,
    pricePending: false,
    currencyConfirmed: true,
    priceSourceUrl: sourceUrl,
    priceEvidenceText: '$rawProcedure 250 EUR',
    priceVerificationStatus: PriceVerificationStatus.officialWebsite,
    rawProcedureText: rawProcedure,
    rawPriceText: '250 EUR',
    extractionMethod: 'html_table',
    sourceType: 'official_clinic',
    procedureFamily: 'filler',
    procedureRelation: relation,
    placeId: 'place_$name',
    priceExtractRevision: kExplorePriceExtractRevision,
  );
}

void main() {
  group('price-list path witness', () {
    test('price-list-medical counts as price menu', () {
      expect(
        exploreSourceUrlLooksLikePriceMenu(
          'https://cclinic.eu/price-list-medical/',
        ),
        isTrue,
      );
      expect(
        exploreSourceUrlLooksLikePriceMenu(
          'https://clinic.example/price_list_botox',
        ),
        isTrue,
      );
    });

    test('Global Action 1 ml stays eligible after accept-time variant', () {
      final c = _fillerCard(
        name: 'Concept Clinic',
        rawProcedure: 'Global Action 1 ml',
        sourceUrl: 'https://cclinic.eu/price-list-medical/',
      );
      // Slim recheck without pageHasFamilyWitness must not Drop the card.
      final current = exploreCurrentProcedureRelation(
        c,
        procedure: 'dermal filler lips cheeks',
      );
      expect(
        current.eligibleForFromPrice ||
            exploreClinicEligibleForVerifiedPool(
              c,
              procedure: 'dermal filler lips cheeks',
              city: 'Tiranë',
            ),
        isTrue,
        reason: 'current=${current.logToken}/${current.reason}',
      );
      expect(
        exploreClinicEligibleForVerifiedPool(
          c,
          procedure: 'dermal filler lips cheeks',
          city: 'Tiranë',
        ),
        isTrue,
      );
    });
  });

  group('Places locality suggestions', () {
    test('rejects restaurants and salons even with country components', () {
      final restaurant = GooglePlacesLocalityHit.tryParse({
        'id': 'places/ChIJ_restaurant',
        'displayName': {'text': 'Bella Italia'},
        'formattedAddress': 'Rruga Myslym Shyri, Tirana, Albania',
        'location': {'latitude': 41.32, 'longitude': 19.81},
        'types': ['restaurant', 'food', 'point_of_interest', 'establishment'],
        'addressComponents': [
          {
            'longText': 'Albania',
            'shortText': 'AL',
            'types': ['country'],
          },
        ],
      });
      expect(restaurant, isNull);

      final city = GooglePlacesLocalityHit.tryParse({
        'id': 'places/ChIJ_tirana',
        'displayName': {'text': 'Tirana'},
        'formattedAddress': 'Tirana, Albania',
        'location': {'latitude': 41.3275, 'longitude': 19.8187},
        'types': ['locality', 'political'],
        'addressComponents': [
          {
            'longText': 'Albania',
            'shortText': 'AL',
            'types': ['country'],
          },
        ],
      });
      expect(city, isNotNull);
      expect(city!.name, 'Tirana');
      expect(city.countryCode, 'AL');
    });
  });
}
