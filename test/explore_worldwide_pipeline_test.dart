import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_city_identity.dart';
import 'package:glowpass/services/explore_clinic_identity.dart';
import 'package:glowpass/services/explore_comparison_session.dart';
import 'package:glowpass/services/explore_pipeline_config.dart';
import 'package:glowpass/services/explore_procedure_ontology.dart';
import 'package:glowpass/services/explore_provider_interfaces.dart';
import 'package:glowpass/services/explore_search_locale.dart';
import 'package:glowpass/services/google_places_service.dart';
import 'package:glowpass/services/openai_service.dart';
import 'package:glowpass/services/explore_price_verification.dart';
import 'package:glowpass/ui/clinic_compare_price_display.dart';

OpenAIClinic _verifiedCard(String name, {double price = 200}) {
  final host = '${packedCanonicalClinicName(name)}.example';
  return OpenAIClinic(
    rank: 1,
    name: name,
    area: '$host · src:https://$host/prices',
    distanceMi: 1,
    rating: 0,
    reviews: 0,
    priceGbp: price.round(),
    priceMin: price,
    priceMax: price,
    priceLabel: '${price.round()} EUR',
    currency: 'EUR',
    brand: 'Lip filler',
    badge: '',
    badgeVariant: 'mid',
    coord: const OpenAICoord(48.85, 2.35),
    hasProcedure: true,
    pricePending: false,
    currencyConfirmed: true,
    priceSourceUrl: 'https://$host/prices',
    priceEvidenceText: 'Lip filler ${price.round()} EUR',
    priceVerificationStatus: PriceVerificationStatus.officialWebsite,
    rawProcedureText: 'Lip filler',
    rawPriceText: '${price.round()} EUR',
    extractionMethod: 'html_table',
    sourceType: 'official_clinic',
    placeId: 'pid_$name',
  );
}

void main() {
  group('worldwide city identity', () {
    test('Paris FR and Paris TX do not share cityId', () {
      final fr = ExploreCityIdentity.resolve(
        rawCity: 'Paris',
        countryCode: 'FR',
        countryName: 'France',
        adminArea: 'Île-de-France',
        latitude: 48.8566,
        longitude: 2.3522,
      );
      final tx = ExploreCityIdentity.resolve(
        rawCity: 'Paris',
        countryCode: 'US',
        countryName: 'United States',
        adminArea: 'Texas',
        latitude: 33.6609,
        longitude: -95.5555,
      );
      expect(fr.cityId, isNot(tx.cityId));
      expect(ExploreCityIdentity.sameLocality(fr, tx), isFalse);
    });

    test('London UK and London Ontario do not share cityId', () {
      final uk = ExploreCityIdentity.resolve(
        rawCity: 'London',
        countryCode: 'GB',
        countryName: 'United Kingdom',
        adminArea: 'England',
        latitude: 51.5074,
        longitude: -0.1278,
      );
      final on = ExploreCityIdentity.resolve(
        rawCity: 'London',
        countryCode: 'CA',
        countryName: 'Canada',
        adminArea: 'Ontario',
        latitude: 42.9849,
        longitude: -81.2453,
      );
      expect(uk.cityId, isNot(on.cityId));
      expect(ExploreCityIdentity.sameLocality(uk, on), isFalse);
    });

    test('accented and unaccented city labels fold together', () {
      expect(exploreCityLabelsAliasMatch('Timișoara', 'Timisoara'), isTrue);
      expect(exploreCityLabelsAliasMatch('Chișinău', 'Chisinau'), isTrue);
      expect(exploreCityLabelsAliasMatch('Iași', 'Iasi'), isTrue);
      expect(exploreCityLabelsAliasMatch('São Paulo', 'Sao Paulo'), isTrue);
      expect(exploreCityLabelsAliasMatch('İstanbul', 'Istanbul'), isTrue);
    });

    test('exonym aliases resolve on the same identity', () {
      final munich = ExploreCityIdentity.resolve(
        rawCity: 'München',
        countryCode: 'DE',
        aliases: const ['Munich', 'München'],
      );
      expect(munich.matchesAliasLabel('Munich'), isTrue);
      expect(munich.matchesAliasLabel('München'), isTrue);

      final dubai = ExploreCityIdentity.resolve(
        rawCity: 'دبي',
        countryCode: 'AE',
        aliases: const ['Dubai', 'دبي'],
      );
      expect(dubai.matchesAliasLabel('Dubai'), isTrue);

      final tokyo = ExploreCityIdentity.resolve(
        rawCity: '東京',
        countryCode: 'JP',
        aliases: const ['Tokyo', '東京'],
      );
      expect(tokyo.matchesAliasLabel('Tokyo'), isTrue);
    });

    test('any worldwide city enters cold-start identity without allowlist', () {
      final nairobi = ExploreCityIdentity.resolve(
        rawCity: 'Nairobi',
        countryCode: 'KE',
        latitude: -1.2921,
        longitude: 36.8219,
      );
      expect(nairobi.cityId, isNotEmpty);
      expect(nairobi.isResolved, isTrue);
      expect(nairobi.canonicalName, contains('nairobi'));
    });

    test('placeId preferred over geo fallback', () {
      final withPlace = ExploreCityIdentity.resolve(
        rawCity: 'Springfield',
        countryCode: 'US',
        adminArea: 'Illinois',
        placeId: 'ChIJ_springfield_il',
      );
      final other = ExploreCityIdentity.resolve(
        rawCity: 'Springfield',
        countryCode: 'US',
        adminArea: 'Missouri',
        placeId: 'ChIJ_springfield_mo',
      );
      expect(withPlace.cityId, startsWith('place_'));
      expect(withPlace.cityId, isNot(other.cityId));
    });
  });

  group('unknown coverage triggers discovery', () {
    test('missing coverage document is unknown and needs discovery', () {
      expect(
        exploreCoverageNeedsDiscovery(
          status: ExploreCoverageStatus.unknown,
          candidateCount: null,
          coverageDocumentExists: false,
        ),
        isTrue,
      );
    });

    test('missing coverage is not treated as complete', () {
      expect(exploreCoverageStatusFromWire(''), ExploreCoverageStatus.unknown);
      expect(
        exploreCoverageNeedsDiscovery(
          status: exploreCoverageStatusFromWire(''),
          coverageDocumentExists: false,
        ),
        isTrue,
      );
    });

    test('thin and failed coverage still need discovery', () {
      expect(
        exploreCoverageNeedsDiscovery(
          status: ExploreCoverageStatus.thin,
          candidateCount: 2,
          coverageDocumentExists: true,
        ),
        isTrue,
      );
      expect(
        exploreCoverageNeedsDiscovery(
          status: ExploreCoverageStatus.failed,
          coverageDocumentExists: true,
        ),
        isTrue,
      );
    });

    test('complete healthy coverage does not need discovery', () {
      expect(
        exploreCoverageNeedsDiscovery(
          status: ExploreCoverageStatus.complete,
          candidateCount: 40,
          verifiedVisibleCount: 4,
          coverageDocumentExists: true,
        ),
        isFalse,
      );
    });

    test('complete status with underfilled verified still needs discovery', () {
      expect(
        exploreCoverageNeedsDiscovery(
          status: ExploreCoverageStatus.complete,
          candidateCount: 40,
          verifiedVisibleCount: 1,
          coverageDocumentExists: true,
        ),
        isTrue,
      );
    });
  });

  group('warm path paints four cached cards immediately', () {
    test('four verified cached cards display immediately', () {
      final cached = [
        for (var i = 1; i <= 4; i++)
          _verifiedCard('Clinic $i', price: 100.0 + i),
      ];
      final plan = planExplorePoolMix(cached.length);
      expect(plan.firestoreShow, 2);
      expect(plan.googleLiveTarget, 2);
      final visible = mixExploreVisibleClinics(
        cachedShown: cached,
        googleShown: const [],
        poolForPad: const [],
        preferredCachedWithFresh: plan.firestoreShow,
      );
      expect(visible.length, 4);
    });

    test('live results replace without reducing visible count', () {
      final cached = [
        for (var i = 1; i <= 4; i++)
          _verifiedCard('Cache $i', price: 110.0 + i),
      ];
      final fresh = [
        _verifiedCard('Fresh A', price: 180),
        _verifiedCard('Fresh B', price: 190),
      ];
      final mid = mixExploreVisibleClinics(
        cachedShown: cached,
        googleShown: fresh.take(1).toList(),
        poolForPad: const [],
        preferredCachedWithFresh: 2,
      );
      expect(mid.length, 4);
      final end = mixExploreVisibleClinics(
        cachedShown: cached,
        googleShown: fresh,
        poolForPad: const [],
        preferredCachedWithFresh: 2,
      );
      expect(end.length, 4);
      expect(end.length, greaterThanOrEqualTo(mid.length));
    });
  });

  group('progressive cold-start composition', () {
    test('first accepted result stays visible while more arrive', () {
      OpenAIComparisonResult? current;
      final first = OpenAIComparisonResult(
        city: 'Nairobi',
        topic: 'Botox',
        topicType: OpenAISearchItemType.procedure,
        summary: '',
        rangeLabel: '',
        mapCenter: const OpenAICoord(-1.29, 36.82),
        clinics: [_verifiedCard('First Clinic', price: 120)],
      );
      current = putBestComparison(previous: current, incoming: first);
      expect(current.clinics.length, 1);

      final second = first.copyWith(
        clinics: [
          _verifiedCard('First Clinic', price: 120),
          _verifiedCard('Second Clinic', price: 140),
        ],
      );
      current = putBestComparison(previous: current, incoming: second);
      expect(current.clinics.length, 2);
    });

    test('candidate verify budget continues past visible target', () {
      expect(ExplorePipelineConfig.visibleTarget, 4);
      expect(
        ExplorePipelineConfig.candidateVerifyLimit,
        greaterThanOrEqualTo(4),
      );
      expect(exploreLiveDiscoveryCandidateCap(4), 16);
    });
  });

  group('generation / stale search isolation', () {
    test('old search generation must not update newer search', () {
      var generation = 0;
      OpenAIComparisonResult? screen;
      void apply(int gen, OpenAIComparisonResult incoming) {
        if (gen != generation) return;
        screen = putBestComparison(previous: screen, incoming: incoming);
      }

      generation = 1;
      apply(
        1,
        OpenAIComparisonResult(
          city: 'Paris',
          topic: 'Botox',
          topicType: OpenAISearchItemType.procedure,
          summary: '',
          rangeLabel: '',
          mapCenter: const OpenAICoord(48.8, 2.3),
          clinics: [_verifiedCard('Paris Clinic')],
        ),
      );
      expect(screen!.clinics.single.name, 'Paris Clinic');

      generation = 2;
      screen = null;
      apply(
        1,
        OpenAIComparisonResult(
          city: 'Paris',
          topic: 'Botox',
          topicType: OpenAISearchItemType.procedure,
          summary: '',
          rangeLabel: '',
          mapCenter: const OpenAICoord(48.8, 2.3),
          clinics: [_verifiedCard('Stale Clinic')],
        ),
      );
      expect(screen, isNull);
      apply(
        2,
        OpenAIComparisonResult(
          city: 'London',
          topic: 'Botox',
          topicType: OpenAISearchItemType.procedure,
          summary: '',
          rangeLabel: '',
          mapCenter: const OpenAICoord(51.5, -0.1),
          clinics: [_verifiedCard('London Clinic')],
        ),
      );
      expect(screen!.clinics.single.name, 'London Clinic');
    });
  });

  group('UI states + exact price labelling', () {
    test('cold city searching copy', () {
      final msg = exploreSearchingVerifiedMessage('Nairobi');
      expect(msg, contains('Searching verified clinic prices in Nairobi'));
      expect(msg, contains('Results will appear as they are verified'));
      expect(
        exploreSearchingVerifiedMessage('Nairobi', hasPartial: true),
        contains('Finding more verified prices'),
      );
    });

    test('thin coverage and technical failure copy', () {
      expect(
        exploreInsufficientDataMessage(
          'Nairobi',
          procedure: 'Botox',
          coverageStatus: 'thin',
        ),
        contains('Limited verified pricing'),
      );
      expect(
        exploreInsufficientDataMessage(
          'Nairobi',
          procedure: 'Botox',
          technicalFailure: true,
        ),
        contains('temporary lookup issue'),
      );
      expect(
        exploreInsufficientDataMessage(
          'Nairobi',
          procedure: 'Botox',
          technicalFailure: true,
        ),
        isNot(contains('No published')),
      );
    });

    test('exact prices are not labelled from', () {
      final c = _verifiedCard('Exact Clinic', price: 1700);
      expect(c.priceLabel.toLowerCase().contains('from'), isFalse);
      expect(c.priceMin, c.priceMax);
    });
  });

  group('Places breaker + ratings optional', () {
    test('Places 429 activates circuit breaker', () {
      GooglePlacesService.resetQuotaCircuitBreaker();
      expect(GooglePlacesService.quotaCircuitOpen, isFalse);
      GooglePlacesService.notePlacesQuotaFailureForTest(
        statusCode: 429,
        body: 'RESOURCE_EXHAUSTED',
      );
      expect(GooglePlacesService.quotaCircuitOpen, isTrue);
      GooglePlacesService.resetQuotaCircuitBreaker();
    });

    test('missing ratings do not reject valid clinics', () {
      final c = _verifiedCard('No Rating Clinic');
      expect(c.rating, 0);
      expect(c.priceMin, greaterThan(0));
      expect(
        c.priceVerificationStatus,
        PriceVerificationStatus.officialWebsite,
      );
    });
  });

  group('provider abstractions + ontology', () {
    test('DefaultCityResolver builds identity for unknown city', () async {
      final resolver = DefaultCityResolver();
      final id = await resolver.resolve(rawCity: 'Accra', countryHint: 'GH');
      expect(id, isNotNull);
      expect(id!.countryCode, 'GH');
      expect(id.cityId, isNotEmpty);
      // Without coords, identity stays unresolved and must not collide.
      expect(id.needsLocationResolution, isTrue);
    });

    test('localized queries include local and english aliases', () {
      final city = ExploreCityIdentity.resolve(
        rawCity: 'Paris',
        countryCode: 'FR',
        countryName: 'France',
        languageCodes: const ['fr', 'en'],
      );
      final qs = exploreLocalizedDiscoveryQueries(
        procedure: 'lip filler',
        city: city,
      );
      expect(qs, isNotEmpty);
      expect(qs.any((q) => q.toLowerCase().contains('paris')), isTrue);
      expect(
        qs.any(
          (q) =>
              q.toLowerCase().contains('levres') ||
              q.toLowerCase().contains('filler') ||
              q.toLowerCase().contains('prix') ||
              q.toLowerCase().contains('price'),
        ),
        isTrue,
      );
    });
  });

  group('branch city contamination guard', () {
    test('different cityIds must not share storage keys', () {
      final a = ExploreCityIdentity.resolve(
        rawCity: 'Paris',
        countryCode: 'FR',
        latitude: 48.85,
        longitude: 2.35,
      );
      final b = ExploreCityIdentity.resolve(
        rawCity: 'Paris',
        countryCode: 'US',
        adminArea: 'Texas',
        latitude: 33.66,
        longitude: -95.55,
      );
      expect(a.storageKey, isNot(b.storageKey));
    });
  });
}
